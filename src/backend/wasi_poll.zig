const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const wasi = std.os.wasi;
const IntrusiveQueue = @import("../queue.zig").IntrusiveQueue;
const heap = @import("../heap.zig");
const xev = @import("../main.zig").WasiPoll;

pub const Loop = struct {
    const TimerHeap = heap.IntrusiveHeap(Timer, void, Timer.less);
    const threaded = std.Target.wasm.featureSetHas(builtin.cpu.features, .atomics);
    const WakeupType = if (threaded) std.atomic.Atomic(bool) else bool;
    const wakeup_init = if (threaded) .{ .value = false } else false;

    /// The number of active completions. This DOES NOT include completions that
    /// are queued in the submissions queue.
    active: usize = 0,

    /// Our queue of submissions that we want to enqueue on the next tick.
    submissions: IntrusiveQueue(Completion) = .{},

    /// Our list of async waiters.
    asyncs: IntrusiveQueue(Completion) = .{},

    /// Batch of subscriptions to send to poll.
    batch: Batch = .{},

    /// Heap of timers.
    timers: TimerHeap = .{ .context = {} },

    /// The wakeup signal variable for Async. If we have Wasm threads
    /// enabled then we use an atomic for this, otherwise we just use a plain
    /// bool because we know we're single threaded.
    wakeup: WakeupType = wakeup_init,

    pub fn init(entries: u13) !Loop {
        _ = entries;
        return .{};
    }

    pub fn deinit(self: *Loop) void {
        _ = self;
    }

    /// Run the event loop. See RunMode documentation for details on modes.
    pub fn run(self: *Loop, mode: xev.RunMode) !void {
        switch (mode) {
            .no_wait => try self.tick(0),
            .once => try self.tick(1),
            .until_done => while (!self.done()) try self.tick(1),
        }
    }

    /// Add a completion to the loop. This doesn't DO anything except queue
    /// the completion. Any configuration errors will be exposed via the
    /// callback on the next loop tick.
    pub fn add(self: *Loop, c: *Completion) void {
        c.flags.state = .adding;
        self.submissions.push(c);
    }

    fn done(self: *Loop) bool {
        return self.active == 0 and
            self.submissions.empty();
    }

    /// Wake up the event loop and force a tick. This only works if there
    /// is a corresponding async_wait completion _already registered_ with
    /// the event loop. If there isn't already a completion, it will still
    /// work, but the async_wait will be triggered on the next loop tick
    /// it is added, and the loop won't wake up until then. This is usually
    /// pointless since completions can only be added from the main thread.
    ///
    /// The completion c doesn't yet have to be registered as a waiter, but
    ///
    ///
    /// This function can be called from any thread.
    pub fn async_notify(self: *Loop, c: *Completion) void {
        assert(c.op == .async_wait);

        if (threaded) {
            self.wakeup.store(true, .SeqCst);
            c.op.async_wait.wakeup.store(true, .SeqCst);
        } else {
            self.wakeup = true;
            c.op.async_wait.wakeup = true;
        }
    }

    /// Tick through the event loop once, waiting for at least "wait" completions
    /// to be processed by the loop itself.
    pub fn tick(self: *Loop, wait: u32) !void {
        // Submit all the submissions. We copy the submission queue so that
        // any resubmits don't cause an infinite loop.
        var queued = self.submissions;
        self.submissions = .{};
        while (queued.pop()) |c| {
            // We ignore any completions that aren't in the adding state.
            // This usually means that we switched them to be deleted or
            // something.
            if (c.flags.state != .adding) continue;
            self.start(c);
        }

        // Wait and process events. We only do this if we have any active.
        if (self.active > 0) {
            var wait_rem = @intCast(usize, wait);
            while (self.active > 0 and (wait == 0 or wait_rem > 0)) {
                const now = try get_now();
                const now_timer: Timer = .{ .next = now };

                // Run our expired timers
                while (self.timers.peek()) |t| {
                    if (!Timer.less({}, t, &now_timer)) break;

                    // Remove the timer
                    assert(self.timers.deleteMin().? == t);

                    // Completion is now dead because it has been processed.
                    // Users can reuse it (unless they specify rearm in
                    // which case we readd it).
                    const c = t.c;
                    c.flags.state = .dead;
                    self.active -= 1;

                    // Lower our remaining count
                    wait_rem -|= 1;

                    // Invoke
                    const action = c.callback(c.userdata, self, c, .{
                        .timer = .expiration,
                    });
                    switch (action) {
                        .disarm => {},
                        .rearm => self.start(c),
                    }
                }

                // Run our async waiters
                if (!self.asyncs.empty()) {
                    const wakeup = if (threaded) self.wakeup.load(.SeqCst) else self.wakeup;
                    if (wakeup) {
                        // Reset to false, we've "woken up" now.
                        if (threaded)
                            self.wakeup.store(false, .SeqCst)
                        else
                            self.wakeup = false;

                        // There is at least one pending async. This isn't efficient
                        // AT ALL. We should improve this in the short term by
                        // using a queue here of asyncs we know should wake up
                        // (we know because we have access to it in async_notify).
                        // I didn't do that right away because we need a Wasm
                        // compatibile std.Thread.Mutex.
                        var asyncs = self.asyncs;
                        self.asyncs = .{};
                        while (asyncs.pop()) |c| {
                            const c_wakeup = if (threaded)
                                c.op.async_wait.wakeup.load(.SeqCst)
                            else
                                c.op.async_wait.wakeup;

                            // If we aren't waking this one up, requeue
                            if (!c_wakeup) {
                                self.asyncs.push(c);
                                continue;
                            }

                            // We are waking up, mark this as dead and call it.
                            c.flags.state = .dead;
                            self.active -= 1;

                            const action = c.callback(c.userdata, self, c, .{ .async_wait = {} });
                            switch (action) {
                                // We disarm by default
                                .disarm => {},

                                // Rearm we just restart it. We use start instead of
                                // add because then it'll become immediately available
                                // if we loop again.
                                .rearm => self.start(c),
                            }
                        }
                    }
                }

                // Setup our timeout. If we have nothing to wait for then
                // we just set an expiring timer so that we still poll but it
                // will return ASAP.
                const timeout: wasi.timestamp_t = if (wait_rem == 0) now else timeout: {
                    // If we have a timer use that value, otherwise, wake up ASAP.
                    const t: *const Timer = self.timers.peek() orelse break :timeout now;
                    break :timeout t.next;
                };
                self.batch.array[0] = .{
                    .userdata = 0,
                    .u = .{
                        .tag = wasi.EVENTTYPE_CLOCK,
                        .u = .{
                            .clock = .{
                                .id = @bitCast(u32, std.os.CLOCK.MONOTONIC),
                                .timeout = timeout,
                                .precision = 1 * std.time.ns_per_ms,
                                .flags = wasi.SUBSCRIPTION_CLOCK_ABSTIME,
                            },
                        },
                    },
                };

                // Build our batch of subscriptions and poll
                var events: [Batch.capacity]wasi.event_t = undefined;
                const subs = self.batch.array[0..self.batch.len];
                assert(events.len >= subs.len);
                var n: usize = 0;
                switch (wasi.poll_oneoff(&subs[0], &events[0], subs.len, &n)) {
                    .SUCCESS => {},
                    else => |err| return std.os.unexpectedErrno(err),
                }

                // Poll!
                for (events[0..n]) |ev| {
                    // A system event
                    if (ev.userdata == 0) continue;

                    const c = @intToPtr(*Completion, @intCast(usize, ev.userdata));

                    // We assume disarm since this is the safest time to access
                    // the completion. It makes rearms slightly more expensive
                    // but not by very much.
                    c.flags.state = .dead;
                    self.batch.put(c);
                    self.active -= 1;

                    const res = c.perform();
                    const action = c.callback(c.userdata, self, c, res);
                    switch (action) {
                        // We disarm by default
                        .disarm => {},

                        // Rearm we just restart it. We use start instead of
                        // add because then it'll become immediately available
                        // if we loop again.
                        .rearm => self.start(c),
                    }
                }

                if (wait == 0) break;
                wait_rem -|= n;
            }
        }
    }

    fn start(self: *Loop, completion: *Completion) void {
        const res_: ?Result = switch (completion.op) {
            .cancel => |v| res: {
                // We stop immediately. We only stop if we are in the
                // "adding" state because cancellation or any other action
                // means we're complete already.
                //
                // For example, if we're in the deleting state, it means
                // someone is cancelling the cancel. So we do nothing. If
                // we're in the dead state it means we ran already.
                if (completion.flags.state == .adding) {
                    if (v.c.op == .cancel) break :res .{ .cancel = CancelError.InvalidOp };
                    self.stop(v.c);
                }

                // We always run timers
                break :res .{ .cancel = {} };
            },

            .read => res: {
                const sub = self.batch.get(completion) catch |err| break :res .{ .read = err };
                sub.* = completion.subscription();
                break :res null;
            },

            .write => res: {
                const sub = self.batch.get(completion) catch |err| break :res .{ .write = err };
                sub.* = completion.subscription();
                break :res null;
            },

            .recv => res: {
                const sub = self.batch.get(completion) catch |err| break :res .{ .recv = err };
                sub.* = completion.subscription();
                break :res null;
            },

            .send => res: {
                const sub = self.batch.get(completion) catch |err| break :res .{ .send = err };
                sub.* = completion.subscription();
                break :res null;
            },

            .accept => res: {
                const sub = self.batch.get(completion) catch |err| break :res .{ .accept = err };
                sub.* = completion.subscription();
                break :res null;
            },

            .shutdown => |v| res: {
                const how: wasi.sdflags_t = switch (v.how) {
                    .both => wasi.SHUT.WR | wasi.SHUT.RD,
                    .recv => wasi.SHUT.RD,
                    .send => wasi.SHUT.WR,
                };

                break :res .{
                    .shutdown = switch (wasi.sock_shutdown(v.socket, how)) {
                        .SUCCESS => {},
                        else => |err| std.os.unexpectedErrno(err),
                    },
                };
            },

            .close => |v| res: {
                std.os.close(v.fd);
                break :res .{ .close = {} };
            },

            .async_wait => res: {
                // Add our async to the list of asyncs
                self.asyncs.push(completion);
                break :res null;
            },

            .timer => |*v| res: {
                // Point back to completion since we need this. In the future
                // we want to use @fieldParentPtr but https://github.com/ziglang/zig/issues/6611
                v.c = completion;

                // Insert the timer into our heap.
                self.timers.insert(v);

                // We always run timers
                break :res null;
            },
        };

        // If we failed to add the completion then we call the callback
        // immediately and mark the error.
        if (res_) |res| {
            switch (completion.callback(
                completion.userdata,
                self,
                completion,
                res,
            )) {
                .disarm => {},

                // If we rearm then we requeue this. Due to the way that tick works,
                // this won't try to re-add immediately it won't happen until the
                // next tick.
                .rearm => self.add(completion),
            }

            return;
        }

        // The completion is now active since it is in our poll set.
        completion.flags.state = .active;

        // Increase our active count
        self.active += 1;
    }

    fn stop(self: *Loop, completion: *Completion) void {
        const rearm: bool = switch (completion.op) {
            .timer => |*v| timer: {
                const c = v.c;

                // Timers needs to be removed from the timer heap only if
                // it has been inserted.
                if (v.heap.inserted()) {
                    self.timers.remove(v);
                }

                // If the timer was never fired, we need to fire it with
                // the cancellation notice.
                if (c.flags.state != .dead) {
                    const action = c.callback(c.userdata, self, c, .{ .timer = .cancel });
                    switch (action) {
                        .disarm => {},
                        .rearm => break :timer true,
                    }
                }

                break :timer false;
            },

            else => unreachable,
        };

        // Decrement the active count so we know how many are running for
        // .until_done run semantics.
        if (completion.flags.state == .active) self.active -= 1;

        // Mark the completion as done
        completion.flags.state = .dead;

        // If we're rearming, add it again immediately
        if (rearm) self.start(completion);
    }

    /// Add a timer to the loop. The timer will initially execute in "next_ms"
    /// from now and will repeat every "repeat_ms" thereafter. If "repeat_ms" is
    /// zero then the timer is oneshot. If "next_ms" is zero then the timer will
    /// invoke immediately (the callback will be called immediately -- as part
    /// of this function call -- to avoid any additional system calls).
    pub fn timer(
        self: *Loop,
        c: *Completion,
        next_ms: u64,
        userdata: ?*anyopaque,
        comptime cb: xev.Callback,
    ) void {
        // Get the absolute time we'll execute this timer next.
        var next_ts: wasi.timestamp_t = ts: {
            var now_ts: wasi.timestamp_t = undefined;
            switch (wasi.clock_time_get(@bitCast(u32, std.os.CLOCK.MONOTONIC), 1, &now_ts)) {
                .SUCCESS => {},
                .INVAL => unreachable,
                else => unreachable,
            }

            // TODO: overflow
            now_ts += next_ms * std.time.ns_per_ms;
            break :ts now_ts;
        };

        c.* = .{
            .op = .{
                .timer = .{
                    .next = next_ts,
                },
            },
            .userdata = userdata,
            .callback = cb,
        };

        self.add(c);
    }

    fn get_now() !wasi.timestamp_t {
        var ts: wasi.timestamp_t = undefined;
        return switch (wasi.clock_time_get(@bitCast(u32, std.os.CLOCK.MONOTONIC), 1, &ts)) {
            .SUCCESS => ts,
            .INVAL => error.UnsupportedClock,
            else => |err| std.os.unexpectedErrno(err),
        };
    }
};

pub const Completion = struct {
    /// Operation to execute. This is only safe to read BEFORE the completion
    /// is queued. After being queued (with "add"), the operation may change.
    op: Operation,

    /// Userdata and callback for when the completion is finished.
    userdata: ?*anyopaque = null,
    callback: xev.Callback,

    //---------------------------------------------------------------
    // Internal fields

    flags: packed struct {
        /// Watch state of this completion. We use this to determine whether
        /// we're active, adding, deleting, etc. This lets us add and delete
        /// multiple times before a loop tick and handle the state properly.
        state: State = .dead,
    } = .{},

    /// Intrusive queue field
    next: ?*Completion = null,

    /// Index in the batch array.
    batch_idx: usize = 0,

    const State = enum(u3) {
        /// completion is not part of any loop
        dead = 0,

        /// completion is in the submission queue
        adding = 1,

        /// completion is in the deletion queue
        deleting = 2,

        /// completion is actively being sent to poll
        active = 3,

        /// completion is being performed and callback invoked
        in_progress = 4,
    };

    fn subscription(self: *Completion) wasi.subscription_t {
        return switch (self.op) {
            .read => |v| .{
                .userdata = @ptrToInt(self),
                .u = .{
                    .tag = wasi.EVENTTYPE_FD_READ,
                    .u = .{
                        .fd_read = .{
                            .fd = v.fd,
                        },
                    },
                },
            },

            .write => |v| .{
                .userdata = @ptrToInt(self),
                .u = .{
                    .tag = wasi.EVENTTYPE_FD_WRITE,
                    .u = .{
                        .fd_write = .{
                            .fd = v.fd,
                        },
                    },
                },
            },

            .accept => |v| .{
                .userdata = @ptrToInt(self),
                .u = .{
                    .tag = wasi.EVENTTYPE_FD_READ,
                    .u = .{
                        .fd_read = .{
                            .fd = v.socket,
                        },
                    },
                },
            },

            .recv => |v| .{
                .userdata = @ptrToInt(self),
                .u = .{
                    .tag = wasi.EVENTTYPE_FD_READ,
                    .u = .{
                        .fd_read = .{
                            .fd = v.fd,
                        },
                    },
                },
            },

            .send => |v| .{
                .userdata = @ptrToInt(self),
                .u = .{
                    .tag = wasi.EVENTTYPE_FD_WRITE,
                    .u = .{
                        .fd_write = .{
                            .fd = v.fd,
                        },
                    },
                },
            },

            .close,
            .async_wait,
            .shutdown,
            .cancel,
            .timer,
            => unreachable,
        };
    }

    /// Perform the operation associated with this completion. This will
    /// perform the full blocking operation for the completion.
    fn perform(self: *Completion) Result {
        return switch (self.op) {
            // This should never happen because we always do these synchronously
            // or in another location.
            .close,
            .async_wait,
            .shutdown,
            .cancel,
            .timer,
            => unreachable,

            .accept => |*op| res: {
                var out_fd: std.os.fd_t = undefined;
                break :res .{
                    .accept = switch (wasi.sock_accept(op.socket, 0, &out_fd)) {
                        .SUCCESS => out_fd,
                        else => |err| std.os.unexpectedErrno(err),
                    },
                };
            },

            .read => |*op| res: {
                const n_ = switch (op.buffer) {
                    .slice => |v| std.os.read(op.fd, v),
                    .array => |*v| std.os.read(op.fd, v),
                };

                break :res .{
                    .read = if (n_) |n|
                        if (n == 0) error.EOF else n
                    else |err|
                        err,
                };
            },

            .write => |*op| res: {
                const n_ = switch (op.buffer) {
                    .slice => |v| std.os.write(op.fd, v),
                    .array => |*v| std.os.write(op.fd, v.array[0..v.len]),
                };

                break :res .{
                    .write = if (n_) |n| n else |err| err,
                };
            },

            .recv => |*op| res: {
                var n: usize = undefined;
                var roflags: wasi.roflags_t = undefined;
                const errno = switch (op.buffer) {
                    .slice => |v| slice: {
                        const iovs = [1]std.os.iovec{std.os.iovec{
                            .iov_base = v.ptr,
                            .iov_len = v.len,
                        }};

                        break :slice wasi.sock_recv(op.fd, &iovs[0], iovs.len, 0, &n, &roflags);
                    },

                    .array => |*v| array: {
                        const iovs = [1]std.os.iovec{std.os.iovec{
                            .iov_base = v,
                            .iov_len = v.len,
                        }};

                        break :array wasi.sock_recv(op.fd, &iovs[0], iovs.len, 0, &n, &roflags);
                    },
                };

                break :res .{
                    .recv = switch (errno) {
                        .SUCCESS => n,
                        else => |err| std.os.unexpectedErrno(err),
                    },
                };
            },

            .send => |*op| res: {
                var n: usize = undefined;
                const errno = switch (op.buffer) {
                    .slice => |v| slice: {
                        const iovs = [1]std.os.iovec_const{std.os.iovec_const{
                            .iov_base = v.ptr,
                            .iov_len = v.len,
                        }};

                        break :slice wasi.sock_send(op.fd, &iovs[0], iovs.len, 0, &n);
                    },

                    .array => |*v| array: {
                        const iovs = [1]std.os.iovec_const{std.os.iovec_const{
                            .iov_base = &v.array,
                            .iov_len = v.len,
                        }};

                        break :array wasi.sock_send(op.fd, &iovs[0], iovs.len, 0, &n);
                    },
                };

                break :res .{
                    .send = switch (errno) {
                        .SUCCESS => n,
                        else => |err| std.os.unexpectedErrno(err),
                    },
                };
            },
        };
    }
};

pub const OperationType = enum {
    cancel,
    accept,
    read,
    write,
    recv,
    send,
    shutdown,
    close,
    timer,
    async_wait,
};

/// The result type based on the operation type. For a callback, the
/// result tag will ALWAYS match the operation tag.
pub const Result = union(OperationType) {
    cancel: CancelError!void,
    accept: AcceptError!std.os.fd_t,
    read: ReadError!usize,
    write: WriteError!usize,
    recv: ReadError!usize,
    send: WriteError!usize,
    shutdown: ShutdownError!void,
    close: CloseError!void,
    timer: TimerError!TimerTrigger,
    async_wait: AsyncError!void,
};

/// All the supported operations of this event loop. These are always
/// backend-specific and therefore the structure and types change depending
/// on the underlying system in use. The high level operations are
/// done by initializing the request handles.
pub const Operation = union(OperationType) {
    cancel: struct {
        c: *Completion,
    },

    accept: struct {
        socket: std.os.socket_t,
    },

    read: struct {
        fd: std.os.fd_t,
        buffer: ReadBuffer,
    },

    write: struct {
        fd: std.os.fd_t,
        buffer: WriteBuffer,
    },

    send: struct {
        fd: std.os.fd_t,
        buffer: WriteBuffer,
    },

    recv: struct {
        fd: std.os.fd_t,
        buffer: ReadBuffer,
    },

    shutdown: struct {
        socket: std.os.socket_t,
        how: std.os.ShutdownHow = .both,
    },

    close: struct {
        fd: std.os.fd_t,
    },

    async_wait: struct {
        wakeup: Loop.WakeupType = Loop.wakeup_init,
    },

    timer: Timer,
};

const Timer = struct {
    /// The absolute time to fire this timer next.
    next: std.os.wasi.timestamp_t,

    /// Internal heap fields.
    heap: heap.IntrusiveHeapField(Timer) = .{},

    /// We point back to completion for now. When issue[1] is fixed,
    /// we can juse use that from our heap fields.
    /// [1]: https://github.com/ziglang/zig/issues/6611
    c: *Completion = undefined,

    fn less(_: void, a: *const Timer, b: *const Timer) bool {
        return a.next < b.next;
    }
};

pub const CancelError = error{
    /// Invalid operation to cancel. You cannot cancel a cancel operation.
    InvalidOp,
};

pub const CloseError = error{
    Unknown,
};

pub const AcceptError = Batch.Error || error{
    Unexpected,
};

pub const ConnectError = error{};

pub const ShutdownError = error{
    Unexpected,
};

pub const ReadError = Batch.Error || std.os.ReadError ||
    error{
    EOF,
    Unknown,
};

pub const WriteError = Batch.Error || std.os.WriteError ||
    error{
    Unknown,
};

pub const AsyncError = error{
    Unknown,
};

pub const TimerError = error{
    Unexpected,
};

pub const TimerTrigger = enum {
    /// Timer expired.
    expiration,

    /// Timer was canceled.
    cancel,

    /// Unused
    request,
};

/// ReadBuffer are the various options for reading.
pub const ReadBuffer = union(enum) {
    /// Read into this slice.
    slice: []u8,

    /// Read into this array, just set this to undefined and it will
    /// be populated up to the size of the array. This is an option because
    /// the other union members force a specific size anyways so this lets us
    /// use the other size in the union to support small reads without worrying
    /// about buffer allocation.
    ///
    /// To know the size read you have to use the return value of the
    /// read operations (i.e. recv).
    ///
    /// Note that the union at the time of this writing could accomodate a
    /// much larger fixed size array here but we want to retain flexiblity
    /// for future fields.
    array: [32]u8,

    // TODO: future will have vectors
};

/// WriteBuffer are the various options for writing.
pub const WriteBuffer = union(enum) {
    /// Write from this buffer.
    slice: []const u8,

    /// Write from this array. See ReadBuffer.array for why we support this.
    array: struct {
        array: [32]u8,
        len: usize,
    },

    // TODO: future will have vectors
};

/// A batch of subscriptions to send to poll_oneoff.
const Batch = struct {
    pub const capacity = 1024;

    /// The array of subscriptions. Sub zero is ALWAYS our loop timeout
    /// so the actual capacity of this for user completions is (len - 1).
    array: [capacity]wasi.subscription_t = undefined,

    /// The length of the used slots in the array including our reserved slot.
    len: usize = 1,

    pub const Error = error{BatchFull};

    /// Initialize a batch entry for the given completion. This will
    /// store the batch index on the completion.
    pub fn get(self: *Batch, c: *Completion) Error!*wasi.subscription_t {
        if (self.len >= self.array.len) return error.BatchFull;
        c.batch_idx = self.len;
        self.len += 1;
        return &self.array[c.batch_idx];
    }

    /// Put an entry back.
    pub fn put(self: *Batch, c: *Completion) void {
        assert(c.batch_idx > 0);
        assert(self.len > 1);

        const old_idx = c.batch_idx;
        c.batch_idx = 0;
        self.len -= 1;

        // If we're empty then we don't worry about swapping.
        if (self.len == 0) return;

        // We're not empty so swap the value we just removed with the
        // last one so our empty slot is always at the end.
        self.array[old_idx] = self.array[self.len];
        const swapped = @intToPtr(*Completion, @intCast(usize, self.array[old_idx].userdata));
        swapped.batch_idx = old_idx;
    }

    test {
        const testing = std.testing;

        var b: Batch = .{};
        var cs: [capacity - 1]Completion = undefined;
        for (cs) |*c, i| {
            c.* = .{ .op = undefined, .callback = undefined };
            const sub = try b.get(c);
            sub.* = .{ .userdata = @ptrToInt(c), .u = undefined };
            try testing.expectEqual(@as(usize, i + 1), c.batch_idx);
        }

        var bad: Completion = .{ .op = undefined, .callback = undefined };
        try testing.expectError(error.BatchFull, b.get(&bad));

        // Put one back
        const old = cs[4].batch_idx;
        const replace = &cs[cs.len - 1];
        b.put(&cs[4]);
        try testing.expect(b.len == capacity - 1);
        try testing.expect(b.array[old].userdata == @ptrToInt(replace));
        try testing.expect(replace.batch_idx == old);

        // Put it back in
        const sub = try b.get(&cs[4]);
        sub.* = .{ .userdata = @ptrToInt(&cs[4]), .u = undefined };
        try testing.expect(cs[4].batch_idx == capacity - 1);
    }
};

test "wasi: timer" {
    const testing = std.testing;

    var loop = try Loop.init(16);
    defer loop.deinit();

    // Add the timer
    var called = false;
    var c1: xev.Completion = undefined;
    loop.timer(&c1, 1, &called, (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *xev.Loop,
            _: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            _ = l;
            _ = r;
            const b = @ptrCast(*bool, ud.?);
            b.* = true;
            return .disarm;
        }
    }).callback);

    // Add another timer
    var called2 = false;
    var c2: xev.Completion = undefined;
    loop.timer(&c2, 100_000, &called2, (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *xev.Loop,
            _: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            _ = l;
            _ = r;
            const b = @ptrCast(*bool, ud.?);
            b.* = true;
            return .disarm;
        }
    }).callback);

    // Tick
    while (!called) try loop.run(.no_wait);
    try testing.expect(called);
    try testing.expect(!called2);
}

test "wasi: timer cancellation" {
    const testing = std.testing;

    var loop = try Loop.init(16);
    defer loop.deinit();

    // Add the timer
    var trigger: ?TimerTrigger = null;
    var c1: xev.Completion = undefined;
    loop.timer(&c1, 100_000, &trigger, (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *xev.Loop,
            _: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            _ = l;
            const ptr = @ptrCast(*?TimerTrigger, @alignCast(@alignOf(?TimerTrigger), ud.?));
            ptr.* = r.timer catch unreachable;
            return .disarm;
        }
    }).callback);

    // Tick and verify we're not called.
    try loop.run(.no_wait);
    try testing.expect(trigger == null);

    // Cancel the timer
    var called = false;
    var c_cancel: xev.Completion = .{
        .op = .{
            .cancel = .{
                .c = &c1,
            },
        },

        .userdata = &called,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = r.cancel catch unreachable;
                const ptr = @ptrCast(*bool, @alignCast(@alignOf(bool), ud.?));
                ptr.* = true;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_cancel);

    // Tick
    try loop.run(.until_done);
    try testing.expect(called);
    try testing.expect(trigger.? == .cancel);
}

test "wasi: canceling a completed operation" {
    const testing = std.testing;

    var loop = try Loop.init(16);
    defer loop.deinit();

    // Add the timer
    var trigger: ?TimerTrigger = null;
    var c1: xev.Completion = undefined;
    loop.timer(&c1, 1, &trigger, (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *xev.Loop,
            _: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            _ = l;
            const ptr = @ptrCast(*?TimerTrigger, @alignCast(@alignOf(?TimerTrigger), ud.?));
            ptr.* = r.timer catch unreachable;
            return .disarm;
        }
    }).callback);

    // Tick and verify we're not called.
    try loop.run(.until_done);
    try testing.expect(trigger.? == .expiration);

    // Cancel the timer
    var called = false;
    var c_cancel: xev.Completion = .{
        .op = .{
            .cancel = .{
                .c = &c1,
            },
        },

        .userdata = &called,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = r.cancel catch unreachable;
                const ptr = @ptrCast(*bool, @alignCast(@alignOf(bool), ud.?));
                ptr.* = true;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_cancel);

    // Tick
    try loop.run(.until_done);
    try testing.expect(called);
    try testing.expect(trigger.? == .expiration);
}

test "wasi: file" {
    const testing = std.testing;

    var loop = try Loop.init(16);
    defer loop.deinit();

    // Create a file
    const path = "zig-cache/wasi-test-file.txt";
    const dir = std.fs.cwd();
    // We can't use dir.createFile yet: https://github.com/ziglang/zig/issues/14324
    const f = f: {
        const w = wasi;
        var oflags = w.O.CREAT | w.O.TRUNC;
        var base: w.rights_t = w.RIGHT.FD_WRITE |
            w.RIGHT.FD_READ |
            w.RIGHT.FD_DATASYNC |
            w.RIGHT.FD_SEEK |
            w.RIGHT.FD_TELL |
            w.RIGHT.FD_FDSTAT_SET_FLAGS |
            w.RIGHT.FD_SYNC |
            w.RIGHT.FD_ALLOCATE |
            w.RIGHT.FD_ADVISE |
            w.RIGHT.FD_FILESTAT_SET_TIMES |
            w.RIGHT.FD_FILESTAT_SET_SIZE |
            w.RIGHT.FD_FILESTAT_GET |
            w.RIGHT.POLL_FD_READWRITE;
        var fdflags: w.fdflags_t = w.FDFLAG.SYNC | w.FDFLAG.RSYNC | w.FDFLAG.DSYNC;
        const fd = try std.os.openatWasi(dir.fd, path, 0x0, oflags, 0x0, base, fdflags);
        break :f std.fs.File{ .handle = fd };
    };
    defer dir.deleteFile(path) catch unreachable;
    defer f.close();

    // Start a reader
    var read_buf: [128]u8 = undefined;
    var read_len: ?usize = null;
    var c_read: xev.Completion = .{
        .op = .{
            .read = .{
                .fd = f.handle,
                .buffer = .{ .slice = &read_buf },
            },
        },

        .userdata = &read_len,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                const ptr = @ptrCast(*?usize, @alignCast(@alignOf(?usize), ud.?));
                ptr.* = r.read catch |err| switch (err) {
                    error.EOF => 0,
                    else => unreachable,
                };
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_read);

    // Tick. The reader should NOT read because we are blocked with no data.
    try loop.run(.until_done);
    try testing.expect(read_len.? == 0);

    // Start a writer
    var write_buf = "hello!";
    var write_len: ?usize = null;
    var c_write: xev.Completion = .{
        .op = .{
            .write = .{
                .fd = f.handle,
                .buffer = .{ .slice = write_buf },
            },
        },

        .userdata = &write_len,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                const ptr = @ptrCast(*?usize, @alignCast(@alignOf(?usize), ud.?));
                ptr.* = r.write catch unreachable;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_write);

    try loop.run(.until_done);
    try testing.expect(write_len.? == write_buf.len);

    // Close
    var c_close: xev.Completion = .{
        .op = .{
            .close = .{
                .fd = f.handle,
            },
        },

        .userdata = null,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = ud;
                _ = l;
                _ = c;
                _ = r.close catch unreachable;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_close);
    try loop.run(.until_done);

    // Read and verify we've written
    const f_verify = try dir.openFile(path, .{});
    defer f_verify.close();
    read_len = try f_verify.readAll(&read_buf);
    try testing.expectEqualStrings(write_buf, read_buf[0..read_len.?]);
}
