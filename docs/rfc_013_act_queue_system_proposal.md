# RFC-013: Act Queue System

## Summary

Thêm hệ thống hàng đợi (queue) cho agent acts để hỗ trợ:
1. **Parallel Execution** — Chạy nhiều acts song song
2. **Priority Queue** — Ưu tiên các act quan trọng
3. **Task Batching** — Nhóm nhiều công việc nhỏ thành một batch
4. **Background Jobs** — Chạy acts không đồng bộ (giống `--bg` của Claude Code)
5. **Session Queuing** — multiple sessions chờ processing

## Current Architecture

```
User Input → AgentLoop.processInput() → executeStep() → return
```

Hiện tại mini-agent chỉ support sequential execution — mỗi user prompt tạo một AgentLoop instance và xử lý tuần tự.

## Proposed Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Act Queue System                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐      │
│  │  Priority    │    │  Normal      │    │  Background  │      │
│  │  Queue (P0)  │    │  Queue (P1)  │    │  Queue (P2)  │      │
│  └──────┬───────┘    └──────┬───────┘    └──────┬───────┘      │
│         │                   │                   │               │
│         └───────────────────┼───────────────────┘               │
│                             ▼                                   │
│                    ┌──────────────────┐                         │
│                    │   Queue Worker   │                         │
│                    │   (single/multi) │                         │
│                    └────────┬─────────┘                         │
│                             │                                   │
│              ┌──────────────┼──────────────┐                    │
│              ▼              ▼              ▼                    │
│        ┌──────────┐   ┌──────────┐   ┌──────────┐              │
│        │  Act 1   │   │  Act 2   │   │  Act 3   │              │
│        │ (serial) │   │(parallel)│   │(background)│             │
│        └──────────┘   └──────────┘   └──────────┘              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Design Details

### 1. Queue Priority Levels

```zig
pub const ActPriority = enum(u8) {
    critical = 0,   // System alerts, plan enforcement
    high = 1,       // User direct commands
    normal = 2,     // Regular tool calls
    low = 3,        // Background tasks, prefetches
    idle = 4,       // Cleanup, compaction
};
```

### 2. Queue Item Structure

```zig
pub const ActQueueItem = struct {
    id: u64,
    priority: ActPriority,
    session_id: []const u8,
    prompt: []const u8,
    /// If set, runs in isolated subagent
    subagent: ?bool,
    /// Timeout in seconds (0 = no timeout)
    timeout_s: u32,
    /// Callback for result (optional)
    callback: ?fn (ActResult) void,
    created_at: i64,
};

pub const ActResult = struct {
    ok: bool,
    output: []const u8,
    duration_ms: u64,
    error: ?[]const u8,
};
```

### 3. Queue Manager

```zig
pub const ActQueue = struct {
    alloc: Allocator,
    items: PriorityQueue(ActQueueItem),
    /// Currently executing acts
    running: std.AutoHashMap(u64, ActHandle),
    /// Completed acts for tracking
    history: std.ArrayList(ActResult),
    
    pub fn enqueue(self: *ActQueue, item: ActQueueItem) ActHandle;
    pub fn dequeue(self: *ActQueue) ?ActQueueItem;
    pub fn cancel(self: *ActQueue, id: u64) bool;
    pub fn peek(self: *const ActQueue) ?ActQueueItem;
    pub fn size(self: *const ActQueue) usize;
};
```

### 4. Integration with AgentLoop

```zig
pub const AgentLoop = struct {
    // ... existing fields ...
    
    /// Act queue for this session
    act_queue: ?*ActQueue = null,
    
    pub fn processInputQueued(
        self: *AgentLoop,
        prompt: []const u8,
        priority: ActPriority,
    ) ActHandle {
        // Enqueue and return handle immediately
    }
};
```

### 5. CLI Interface

```bash
# Run in background (returns handle)
mini-agent --bg "Do something complex"

# Check job status
mini-agent --status <job_id>

# List all jobs
mini-agent --jobs

# Cancel a job
mini-agent --cancel <job_id>

# Priority execution
mini-agent --priority high "Urgent task"

# Batch execution
mini-agent --batch "task1" "task2" "task3"
```

## Use Cases

### 1. Parallel Research
```
User: "Research React vs Vue, then write comparison"
→ Act 1: Research React (parallel)
→ Act 2: Research Vue (parallel)
→ Act 3: Write comparison (after 1&2 complete)
```

### 2. Long-running Tasks
```
User: "Monitor this server for 1 hour"
→ Background act with 3600s timeout
→ Returns job ID
→ User can check status anytime
```

### 3. Priority Interrupt
```
Normal task running...
User sends urgent request
→ Current task paused/saved
→ Urgent task executed
→ Resume original task
```

### 4. Batch Processing
```
User: "Process these 10 files"
→ 10 acts enqueued
→ Processed in parallel (configurable concurrency)
→ Single consolidated result
```

## Implementation Plan

1. **Phase 1**: Core queue data structures (`src/core/act_queue.zig`)
2. **Phase 2**: Queue Manager with priority handling
3. **Phase 3**: Integration with AgentLoop
4. **Phase 4**: CLI flags and background mode
5. **Phase 5**: Parallel execution support
6. **Phase 6**: Session persistence for queued acts

## API Compatibility

- Backward compatible — existing `processInput()` continues to work
- New `processInputQueued()` for queue-based execution
- Subagent system already supports isolation, minimal changes needed

## Metrics & Monitoring

```zig
pub const QueueMetrics = struct {
    enqueued: usize,
    dequeued: usize,
    completed: usize,
    failed: usize,
    cancelled: usize,
    avg_wait_time_ms: u64,
    avg_execution_time_ms: u64,
    current_queue_size: usize,
    current_running_count: usize,
};
```

## References

- [oh-my-pi task system](https://github.com/can1357/oh-my-pi) — Fan-out subagents with typed results
- [Claude Code --bg](https://docs.anthropic.com/en/docs/claude-code/cli#background-mode) — Background sessions
- [ACP Server](../src/acp/server.zig) — Existing JSON-RPC infrastructure for future扩展
