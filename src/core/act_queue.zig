//! act_queue.zig — Act Queue System for mini-agent.
//!
//! Provides priority-based queueing for agent acts, enabling:
//! - Parallel execution of independent tasks
//! - Priority-based scheduling (critical > high > normal > low)
//! - Background execution with job handles
//! - Session persistence for long-running tasks
//!
//! ## Architecture
//! ```
//! User Prompt → ActQueue.enqueue() → QueueWorker.process() → ActResult
//!                                         ↑
//!                              Priority-based scheduling
//! ```
//!
//! ## Usage
//! ```zig
//! var queue = ActQueue.init(allocator);
//! defer queue.deinit();
//!
//! const handle = try queue.enqueue(.{
//!     .priority = .normal,
//!     .prompt = "Analyze this code",
//!     .session_id = session_id,
//! });
//!
//! // Later...
//! const result = queue.waitFor(handle, timeout_ms);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");

// ---------------------------------------------------------------------------
// Priority Levels
// ---------------------------------------------------------------------------

/// Act priority levels. Lower value = higher priority.
pub const ActPriority = enum(u8) {
    /// Critical: System alerts, plan enforcement, rate limit recovery
    critical = 0,
    /// High: User direct commands, urgent requests
    high = 1,
    /// Normal: Regular agent operations
    normal = 2,
    /// Low: Background tasks, prefetches, housekeeping
    low = 3,
    /// Idle: Cleanup, compaction, non-urgent work
    idle = 4,
};

// ---------------------------------------------------------------------------
// Queue Item
// ---------------------------------------------------------------------------

/// A single act to be executed by the agent.
pub const ActQueueItem = struct {
    /// Unique identifier for this act.
    id: u64,
    /// Priority level.
    priority: ActPriority,
    /// Session ID this act belongs to.
    session_id: []const u8,
    /// User prompt/text for this act.
    prompt: []const u8,
    /// If true, run in isolated subagent context.
    subagent: bool,
    /// Timeout in seconds (0 = no timeout).
    timeout_s: u32,
    /// Optional callback for result notification.
    callback: ?*const fn (*ActQueue, u64, ActResult) void,
    /// Timestamp when this act was created.
    created_at: i64,
    /// Parent act ID (for chaining dependencies).
    parent_id: ?u64 = null,
};

// ---------------------------------------------------------------------------
// Act Result
// ---------------------------------------------------------------------------

/// Result of executing an act.
pub const ActResult = struct {
    /// Whether the act completed successfully.
    ok: bool,
    /// Output text from the act.
    output: []const u8,
    /// Duration in milliseconds.
    duration_ms: u64,
    /// Error message if failed.
    error: ?[]const u8,
    /// Act ID that produced this result.
    act_id: u64,
    /// Priority of the act.
    priority: ActPriority,
    /// Number of tool calls made.
    tool_calls_count: usize,
    /// Number of tokens used.
    tokens_used: usize,
};

// ---------------------------------------------------------------------------
// Act Handle
// ---------------------------------------------------------------------------

/// Handle returned when enqueuing an act.
/// Used to poll status, wait for completion, or cancel.
pub const ActHandle = struct {
    /// The act ID.
    id: u64,
    /// Reference to the queue (for polling).
    queue: *ActQueue,
};

// ---------------------------------------------------------------------------
// Priority Queue Comparator
// ---------------------------------------------------------------------------

fn lessThan(ctx: void, a: ActQueueItem, b: ActQueueItem) bool {
    _ = ctx;
    // Lower enum value = higher priority = should come first
    return @intFromEnum(a.priority) < @intFromEnum(b.priority);
}

// ---------------------------------------------------------------------------
// Queue Metrics
// ---------------------------------------------------------------------------

/// Metrics for monitoring queue performance.
pub const QueueMetrics = struct {
    enqueued: usize = 0,
    dequeued: usize = 0,
    completed: usize = 0,
    failed: usize = 0,
    cancelled: usize = 0,
    total_wait_time_ms: u64 = 0,
    total_execution_time_ms: u64 = 0,
    current_queue_size: usize = 0,
    current_running_count: usize = 0,

    pub fn avgWaitTime(self: *const QueueMetrics) u64 {
        if (self.enqueued == 0) return 0;
        return self.total_wait_time_ms / @as(u64, @intCast(self.enqueued));
    }

    pub fn avgExecutionTime(self: *const QueueMetrics) u64 {
        const done = self.completed + self.failed;
        if (done == 0) return 0;
        return self.total_execution_time_ms / @as(u64, @intCast(done));
    }
};

// ---------------------------------------------------------------------------
// Act Queue
// ---------------------------------------------------------------------------

/// Priority queue for managing agent acts.
pub const ActQueue = struct {
    alloc: Allocator,
    /// Priority queue of pending acts.
    pq: std.heap.PriorityQueue(ActQueueItem, void),
    /// Map from act ID to act info (for running/completed).
    acts: std.AutoHashMap(u64, ActQueueItem),
    /// Map from act ID to result (for completed acts).
    results: std.AutoHashMap(u64, ActResult),
    /// Condition variable for waiting on completion.
    signal: std.Thread.Condition,
    /// Mutex for protecting shared state.
    mutex: std.Thread.Mutex,
    /// Next act ID counter.
    next_id: u64,
    /// Queue metrics.
    metrics: QueueMetrics,
    /// Maximum concurrent acts (0 = unlimited).
    max_concurrent: usize,
    /// Whether the queue is shutting down.
    shutting_down: bool,

    pub fn init(alloc: Allocator) ActQueue {
        return ActQueue{
            .alloc = alloc,
            .pq = std.heap.PriorityQueue(ActQueueItem, void).init(
                alloc,
                {},
                lessThan,
            ),
            .acts = std.AutoHashMap(u64, ActQueueItem).init(alloc),
            .results = std.AutoHashMap(u64, ActResult).init(alloc),
            .signal = .{},
            .mutex = .{},
            .next_id = 1,
            .metrics = .{},
            .max_concurrent = 0,
            .shutting_down = false,
        };
    }

    pub fn deinit(self: *ActQueue) void {
        // Drain remaining items
        while (self.pq.popOrNull()) |item| {
            self.alloc.free(item.prompt);
            self.alloc.free(item.session_id);
        }
        self.pq.deinit();
        self.acts.deinit();
        self.results.deinit();
    }

    /// Enqueue a new act. Returns ActHandle for tracking.
    pub fn enqueue(self: *ActQueue, item: ActQueueItem) ActHandle {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Assign ID if not set
        var actual_item = item;
        if (actual_item.id == 0) {
            actual_item.id = self.next_id;
            self.next_id += 1;
        }

        // Store the act
        self.acts.put(actual_item.id, actual_item) catch unreachable;

        // Add to priority queue
        self.pq.add(actual_item);

        // Update metrics
        self.metrics.enqueued += 1;
        self.metrics.current_queue_size += 1;

        // Notify waiting threads
        self.signal.notify();

        return ActHandle{
            .id = actual_item.id,
            .queue = self,
        };
    }

    /// Dequeue the highest priority act. Returns null if queue is empty.
    pub fn dequeue(self: *ActQueue) ?ActQueueItem {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pq.items.len == 0) return null;

        const item = self.pq.remove();
        self.metrics.current_queue_size -= 1;
        self.metrics.dequeued += 1;

        return item;
    }

    /// Wait for an act to complete. Returns ActResult or error.Timeout.
    pub fn waitFor(self: *ActQueue, handle: ActHandle, timeout_ms: u64) !ActResult {
        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));

        self.mutex.lock();
        defer self.mutex.unlock();

        while (true) {
            // Check if completed
            if (self.results.get(handle.id)) |result| {
                return result;
            }

            // Check timeout
            const now = std.time.milliTimestamp();
            if (now >= deadline) {
                return error.Timeout;
            }

            // Wait with timeout
            const remaining = deadline - now;
            if (!self.signal.timedWait(&self.mutex, remaining)) {
                // Check again after wakeup
                if (self.results.get(handle.id)) |result| {
                    return result;
                }
                return error.Timeout;
            }
        }
    }

    /// Cancel an act. Returns true if cancelled, false if not found or already running.
    pub fn cancel(self: *ActQueue, id: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Try to remove from queue
        var found = false;
        var i: usize = 0;
        while (i < self.pq.items.len) {
            if (self.pq.items[i].id == id) {
                // Swap with last and remove
                const last = self.pq.items.len - 1;
                if (i != last) {
                    self.pq.items[i] = self.pq.items[last];
                    self.pq.siftUp(i);
                    self.pq.siftDown(i);
                } else {
                    _ = self.pq.remove();
                }
                found = true;
                break;
            }
            i += 1;
        }

        if (found) {
            self.metrics.current_queue_size -= 1;
            self.metrics.cancelled += 1;
            return true;
        }

        // Check if already running/completed
        return self.acts.get(id) != null and self.results.get(id) == null;
    }

    /// Get status of an act.
    pub fn getStatus(self: *const ActQueue, id: u64) ?enum { pending, running, completed, failed, cancelled } {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.results.get(id)) |_| {
            return .completed;
        }
        if (self.acts.get(id)) |_| {
            // Check if still in queue
            for (self.pq.items) |item| {
                if (item.id == id) return .pending;
            }
            return .running;
        }
        return null;
    }

    /// Get next act without removing from queue (peek).
    pub fn peek(self: *const ActQueue) ?ActQueueItem {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pq.items.len == 0) return null;
        return self.pq.items[0];
    }

    /// Get current queue size.
    pub fn size(self: *const ActQueue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.pq.items.len;
    }

    /// Get metrics snapshot.
    pub fn getMetrics(self: *const ActQueue) QueueMetrics {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.metrics;
    }

    /// Signal completion of an act. Called by executor.
    pub fn complete(self: *ActQueue, id: u64, result: ActResult) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.results.put(id, result) catch {};
        self.metrics.completed += 1;
        self.metrics.current_running_count -= 1;
        self.signal.notify();
    }

    /// Signal failure of an act.
    pub fn fail(self: *ActQueue, id: u64, error_msg: []const u8, duration_ms: u64) void {
        const result = ActResult{
            .ok = false,
            .output = "",
            .duration_ms = duration_ms,
            .error = error_msg,
            .act_id = id,
            .priority = .normal,
            .tool_calls_count = 0,
            .tokens_used = 0,
        };
        self.complete(id, result);
        self.metrics.failed += 1;
    }

    /// Wait until queue is empty or timeout.
    pub fn waitEmpty(self: *ActQueue, timeout_ms: u64) bool {
        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));

        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.pq.items.len > 0 or self.metrics.current_running_count > 0) {
            const now = std.time.milliTimestamp();
            if (now >= deadline) return false;

            const remaining = deadline - now;
            if (!self.signal.timedWait(&self.mutex, remaining)) {
                return self.pq.items.len == 0 and self.metrics.current_running_count == 0;
            }
        }
        return true;
    }

    /// Check if queue is empty.
    pub fn isEmpty(self: *const ActQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.pq.items.len == 0;
    }

    /// Clear all pending acts.
    pub fn clear(self: *ActQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.pq.popOrNull()) |item| {
            self.alloc.free(item.prompt);
            self.alloc.free(item.session_id);
        }
        self.pq.clearAndDeinit();
        self.metrics.current_queue_size = 0;
    }

    /// Start shutdown sequence.
    pub fn startShutdown(self: *ActQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.shutting_down = true;
        self.signal.notifyAll();
    }

    /// Check if shutting down.
    pub fn isShuttingDown(self: *const ActQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.shutting_down;
    }
};

// ---------------------------------------------------------------------------
// Helper Functions
// ---------------------------------------------------------------------------

fn lessThan(ctx: void, a: ActQueueItem, b: ActQueueItem) bool {
    _ = ctx;
    // Lower enum value = higher priority = should come first
    return @intFromEnum(a.priority) < @intFromEnum(b.priority);
}

// ---------------------------------------------------------------------------
// Thread-safe Queue Iterator
// ---------------------------------------------------------------------------

/// Iterator for processing queue items.
pub const QueueIterator = struct {
    queue: *ActQueue,
    stopped: bool,

    pub fn init(queue: *ActQueue) QueueIterator {
        return .{ .queue = queue, .stopped = false };
    }

    /// Get next item, blocking until available or stopped.
    pub fn next(self: *QueueIterator, timeout_ms: u64) ?ActQueueItem {
        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));

        while (true) {
            if (self.stopped) return null;

            self.queue.mutex.lock();
            const item = self.queue.pq.popOrNull();
            if (item != null) {
                self.queue.mutex.unlock();
                return item.?;
            }
            self.queue.mutex.unlock();

            // Check timeout
            const now = std.time.milliTimestamp();
            if (now >= deadline) return null;

            // Wait for notification
            std.time.sleep(10 * std.time.ms_per_s); // 10ms poll interval
        }
    }

    /// Stop the iterator.
    pub fn stop(self: *QueueIterator) void {
        self.stopped = true;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "act_queue: basic enqueue/dequeue" {
    var queue = ActQueue.init(std.testing.allocator);
    defer queue.deinit();

    const item = ActQueueItem{
        .id = 0,
        .priority = .normal,
        .session_id = "test-session",
        .prompt = "Test prompt",
        .subagent = false,
        .timeout_s = 0,
        .callback = null,
        .created_at = 0,
    };

    const handle = queue.enqueue(item);
    try std.testing.expectEqual(@as(u64, 1), handle.id);
    try std.testing.expectEqual(@as(usize, 1), queue.size());

    const dequeued = queue.dequeue() orelse unreachable;
    try std.testing.expectEqualSlices(u8, "Test prompt", dequeued.prompt);
    try std.testing.expectEqual(@as(usize, 0), queue.size());
}

test "act_queue: priority ordering" {
    var queue = ActQueue.init(std.testing.allocator);
    defer queue.deinit();

    // Enqueue in reverse priority order
    _ = queue.enqueue(ActQueueItem{ .id = 0, .priority = .low, .session_id = "s", .prompt = "low", .subagent = false, .timeout_s = 0, .callback = null, .created_at = 0 });
    _ = queue.enqueue(ActQueueItem{ .id = 0, .priority = .critical, .session_id = "s", .prompt = "critical", .subagent = false, .timeout_s = 0, .callback = null, .created_at = 0 });
    _ = queue.enqueue(ActQueueItem{ .id = 0, .priority = .high, .session_id = "s", .prompt = "high", .subagent = false, .timeout_s = 0, .callback = null, .created_at = 0 });

    // Should dequeue in priority order: critical, high, low
    const first = queue.dequeue() orelse unreachable;
    try std.testing.expectEqualStrings("critical", first.prompt);

    const second = queue.dequeue() orelse unreachable;
    try std.testing.expectEqualStrings("high", second.prompt);

    const third = queue.dequeue() orelse unreachable;
    try std.testing.expectEqualStrings("low", third.prompt);
}

test "act_queue: cancel" {
    var queue = ActQueue.init(std.testing.allocator);
    defer queue.deinit();

    const handle = queue.enqueue(ActQueueItem{ .id = 0, .priority = .normal, .session_id = "s", .prompt = "cancel me", .subagent = false, .timeout_s = 0, .callback = null, .created_at = 0 });
    try std.testing.expect(queue.cancel(handle.id));
    try std.testing.expectEqual(@as(usize, 0), queue.size());
}

test "act_queue: wait for completion" {
    var queue = ActQueue.init(std.testing.allocator);
    defer queue.deinit();

    const handle = queue.enqueue(ActQueueItem{ .id = 0, .priority = .normal, .session_id = "s", .prompt = "complete me", .subagent = false, .timeout_s = 0, .callback = null, .created_at = 0 });

    // Simulate completion in another thread
    std.Thread.spawn(.{}, () => {
        std.time.sleep(10 * std.time.ms_per_s);
        queue.complete(handle.id, ActResult{
            .ok = true,
            .output = "done",
            .duration_ms = 100,
            .error = null,
            .act_id = handle.id,
            .priority = .normal,
            .tool_calls_count = 2,
            .tokens_used = 100,
        });
    }).detach();

    const result = queue.waitFor(handle, 1000) catch unreachable;
    try std.testing.expect(result.ok);
    try std.testing.expectEqualStrings("done", result.output);
}

test "act_queue: timeout" {
    var queue = ActQueue.init(std.testing.allocator);
    defer queue.deinit();

    const handle = queue.enqueue(ActQueueItem{ .id = 0, .priority = .normal, .session_id = "s", .prompt = "timeout me", .subagent = false, .timeout_s = 0, .callback = null, .created_at = 0 });

    // Never complete — should timeout
    const result = queue.waitFor(handle, 50) catch |err| {
        try std.testing.expectEqual(error.Timeout, err);
        return;
    };
    try std.testing.expect(false); // Should not reach here
    _ = result;
}
