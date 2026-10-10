//! M8: per-page FIFO command queue.
//!
//! Commands for the same page run strictly one at a time in arrival order;
//! commands for different pages do not wait on each other. The queue knows
//! nothing about JSON-RPC or sockets: callers `acquire` a ticket for a page
//! id, run the command, then `release` the ticket.
const std = @import("std");

pub const Ticket = *Waiter;

/// One queued or running command. Owned by the queue; valid from `acquire`
/// until `release`.
pub const Waiter = struct {
    page: *PageLine,
    /// Set by `shutdown`; the engine checks it between attempts.
    cancelled: std.atomic.Value(bool) = .init(false),
    /// Milliseconds spent waiting for earlier same-page commands.
    wait_ms: u64 = 0,
};

const PageLine = struct {
    /// Head is the running command; the rest wait in arrival order.
    waiters: std.ArrayListUnmanaged(*Waiter) = .empty,
    /// The map key (owned by the line's map entry).
    key: []const u8 = "",
};

pub const PageCommandQueue = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    pages: std.StringHashMapUnmanaged(*PageLine) = .empty,
    shutting_down: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) PageCommandQueue {
        return .{ .allocator = allocator, .io = io };
    }

    /// All tickets must have been released.
    pub fn deinit(self: *PageCommandQueue) void {
        var it = self.pages.iterator();
        while (it.next()) |entry| {
            std.debug.assert(entry.value_ptr.*.waiters.items.len == 0);
            entry.value_ptr.*.waiters.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.pages.deinit(self.allocator);
        self.* = undefined;
    }

    /// Blocks until every earlier command for `page_id` has released.
    /// Returns error.Cancelled if the queue shuts down while waiting.
    pub fn acquire(self: *PageCommandQueue, page_id: []const u8) error{ OutOfMemory, Cancelled }!Ticket {
        const started = self.nowMs();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.shutting_down) return error.Cancelled;

        const line = try self.pageLine(page_id);
        // Out of memory below: a line this call just created (still empty)
        // must not stay behind (under the mutex, nobody else can fill it).
        errdefer if (line.waiters.items.len == 0) self.dropLine(line);
        const waiter = try self.allocator.create(Waiter);
        errdefer self.allocator.destroy(waiter);
        waiter.* = .{ .page = line };
        try line.waiters.append(self.allocator, waiter);

        // An uncontended acquire reports exactly 0 (no clock granularity
        // noise); only real waits are measured.
        if (line.waiters.items[0] == waiter) return waiter;
        while (line.waiters.items[0] != waiter) {
            if (self.shutting_down) {
                // `waiter` is freed by the errdefer above.
                removeWaiter(line, waiter);
                self.cond.broadcast(self.io);
                return error.Cancelled;
            }
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
        waiter.wait_ms = self.nowMs() -| started;
        return waiter;
    }

    pub fn release(self: *PageCommandQueue, ticket: Ticket) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const line = ticket.page;
        removeWaiter(line, ticket);
        self.allocator.destroy(ticket);
        // N23: an idle line goes at once (window ids are never reused, and
        // any page id may be asked for), so lines never accumulate.
        if (line.waiters.items.len == 0) self.dropLine(line);
        self.cond.broadcast(self.io);
    }

    /// Lines currently kept (test hook).
    pub fn lineCount(self: *PageCommandQueue) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.pages.count();
    }

    /// Caller holds the mutex; `line` has no waiters.
    fn dropLine(self: *PageCommandQueue, line: *PageLine) void {
        const key = line.key;
        _ = self.pages.remove(key);
        self.allocator.free(key);
        line.waiters.deinit(self.allocator);
        self.allocator.destroy(line);
    }

    /// Cancels every queued command and flags running ones; later acquires
    /// fail with error.Cancelled.
    pub fn shutdown(self: *PageCommandQueue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.shutting_down = true;
        var it = self.pages.valueIterator();
        while (it.next()) |line| {
            for (line.*.waiters.items) |waiter| waiter.cancelled.store(true, .release);
        }
        self.cond.broadcast(self.io);
    }

    /// Commands waiting behind the running one for `page_id` (test hook).
    pub fn pendingCount(self: *PageCommandQueue, page_id: []const u8) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const line = self.pages.get(page_id) orelse return 0;
        return line.waiters.items.len -| 1;
    }

    fn pageLine(self: *PageCommandQueue, page_id: []const u8) error{OutOfMemory}!*PageLine {
        if (self.pages.get(page_id)) |line| return line;
        const key = try self.allocator.dupe(u8, page_id);
        errdefer self.allocator.free(key);
        const line = try self.allocator.create(PageLine);
        errdefer self.allocator.destroy(line);
        line.* = .{ .key = key };
        try self.pages.put(self.allocator, key, line);
        return line;
    }

    fn nowMs(self: *PageCommandQueue) u64 {
        const ms = std.Io.Clock.now(.awake, self.io).toMilliseconds();
        return if (ms < 0) 0 else @intCast(ms);
    }
};

fn removeWaiter(line: *PageLine, waiter: *Waiter) void {
    for (line.waiters.items, 0..) |item, i| {
        if (item == waiter) {
            _ = line.waiters.orderedRemove(i);
            return;
        }
    }
}
