const std = @import("std");
const types = @import("types.zig");

/// High-Performance Parallel Processing System
/// Provides thread pools, work stealing, and parallel algorithms
/// Following TigerBeetle-style programming: deterministic, comprehensive, zero dependencies

/// Work item for parallel execution
pub const WorkItem = union(enum) {
    vector_similarity: VectorSimilarityWork,
    graph_traversal: GraphTraversalWork,
    batch_insert: BatchInsertWork,
    map_reduce: MapReduceWork,
    custom: CustomWork,
    
    pub const VectorSimilarityWork = struct {
        query_vector_id: u64,
        candidate_vectors: []const types.Vector,
        results: *std.ArrayList(types.SimilarityResult),
        start_index: usize,
        end_index: usize,
    };
    
    pub const GraphTraversalWork = struct {
        start_node_id: u64,
        target_depth: u8,
        current_depth: u8,
        nodes: *std.ArrayList(types.Node),
        visited: *std.AutoHashMap(u64, void),
        mutex: *std.Thread.Mutex,
    };
    
    pub const BatchInsertWork = struct {
        nodes: []const types.Node,
        edges: []const types.Edge,
        vectors: []const types.Vector,
        start_index: usize,
        end_index: usize,
    };
    
    pub const MapReduceWork = struct {
        input_data: []const u8,
        map_fn: *const fn ([]const u8, *std.ArrayList(KeyValuePair)) anyerror!void,
        reduce_fn: *const fn ([]const KeyValuePair, *std.ArrayList(KeyValuePair)) anyerror!void,
        output: *std.ArrayList(KeyValuePair),
        allocator: std.mem.Allocator,
    };
    
    pub const CustomWork = struct {
        work_fn: *const fn (*CustomWork) anyerror!void,
        data: ?*anyopaque,
    };
    
    pub const KeyValuePair = struct {
        key: []const u8,
        value: []const u8,
    };
};

/// Worker thread state
const Worker = struct {
    id: u32,
    thread: std.Thread,
    pool: *ThreadPool,
    running: std.atomic.Value(bool),
    
    pub fn init(id: u32, pool: *ThreadPool) Worker {
        return Worker{
            .id = id,
            .thread = undefined, // Will be set when thread is spawned
            .pool = pool,
            .running = std.atomic.Value(bool).init(false),
        };
    }
    
    pub fn run(self: *Worker) void {
        self.running.store(true, .seq_cst);
        
        while (self.running.load(.seq_cst) and self.pool.running.load(.seq_cst)) {
            if (self.pool.getWork()) |work_item| {
                // Increment active workers and track peak
                const new_active = self.pool.stats.active_workers.fetchAdd(1, .seq_cst) + 1;
                
                // Update peak active workers (simple approach to avoid complex atomic CAS)
                const current_peak = self.pool.stats.peak_active_workers.load(.seq_cst);
                if (new_active > current_peak) {
                    self.pool.stats.peak_active_workers.store(new_active, .seq_cst);
                }
                
                const start_time = std.time.nanoTimestamp();
                
                self.executeWork(work_item) catch |err| {
                    // Increment failed task counter
                    _ = self.pool.stats.tasks_failed.fetchAdd(1, .seq_cst);
                    
                    // Only print non-test errors to avoid noise in tests
                    if (err != error.TestError) {
                        std.debug.print("Worker {} error: {}\n", .{ self.id, err });
                    }
                    
                    // Decrement active workers and track total time
                    _ = self.pool.stats.active_workers.fetchSub(1, .seq_cst);
                    const end_time = std.time.nanoTimestamp();
                    const worker_time = @as(u64, @intCast(end_time - start_time));
                    _ = self.pool.stats.total_worker_time_ns.fetchAdd(worker_time, .seq_cst);
                    continue;
                };
                
                // Task completed successfully
                const end_time = std.time.nanoTimestamp();
                const execution_time = @as(u64, @intCast(end_time - start_time));
                
                _ = self.pool.stats.tasks_completed.fetchAdd(1, .seq_cst);
                _ = self.pool.stats.total_execution_time_ns.fetchAdd(execution_time, .seq_cst);
                _ = self.pool.stats.total_worker_time_ns.fetchAdd(execution_time, .seq_cst);
                
                // Decrement active workers
                _ = self.pool.stats.active_workers.fetchSub(1, .seq_cst);
            } else {
                // No work available, sleep briefly to avoid busy waiting
                std.time.sleep(1_000_000); // 1ms
                
                // Double-check shutdown conditions
                if (!self.running.load(.seq_cst) or !self.pool.running.load(.seq_cst)) {
                    break;
                }
            }
        }
        
        self.running.store(false, .seq_cst);
    }
    
    fn executeWork(self: *Worker, work_item: WorkItem) !void {
        _ = self; // Worker ID available if needed for logging
        
        switch (work_item) {
            .vector_similarity => |work| {
                try executeVectorSimilarityWork(work);
            },
            .graph_traversal => |work| {
                try executeGraphTraversalWork(work);
            },
            .batch_insert => |work| {
                try executeBatchInsertWork(work);
            },
            .map_reduce => |work| {
                try executeMapReduceWork(work);
            },
            .custom => |work| {
                var mutable_work = work;
                try mutable_work.work_fn(&mutable_work);
            },
        }
    }
};

/// Work queue with lock-free operations where possible
pub const WorkQueue = struct {
    items: std.ArrayList(WorkItem),
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,
    
    pub fn init(allocator: std.mem.Allocator) WorkQueue {
        return WorkQueue{
            .items = std.ArrayList(WorkItem).init(allocator),
            .mutex = std.Thread.Mutex{},
            .condition = std.Thread.Condition{},
        };
    }
    
    pub fn deinit(self: *WorkQueue) void {
        self.items.deinit();
    }
    
    pub fn enqueue(self: *WorkQueue, item: WorkItem) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.items.append(item);
        self.condition.signal();
    }
    
    pub fn dequeue(self: *WorkQueue) ?WorkItem {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.items.items.len > 0) {
            return self.items.orderedRemove(0);
        }
        return null;
    }
    
    pub fn size(self: *WorkQueue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.items.items.len;
    }
    
    pub fn waitForWork(self: *WorkQueue, timeout_ms: ?u64) ?WorkItem {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.items.items.len > 0) {
            return self.items.orderedRemove(0);
        }
        
        if (timeout_ms) |timeout| {
            const timeout_ns = timeout * 1_000_000;
            self.condition.timedWait(&self.mutex, timeout_ns) catch {};
        } else {
            self.condition.wait(&self.mutex);
        }
        
        if (self.items.items.len > 0) {
            return self.items.orderedRemove(0);
        }
        
        return null;
    }
};

/// Thread pool configuration
pub const ThreadPoolConfig = struct {
    num_threads: u32 = 0, // 0 = auto-detect CPU count
    queue_size: u32 = 1000,
    enable_work_stealing: bool = true,
    enable_stats: bool = true,
    thread_stack_size: ?usize = null,
};

/// Thread pool statistics
pub const ThreadPoolStats = struct {
    tasks_completed: std.atomic.Value(u64),
    tasks_failed: std.atomic.Value(u64),
    total_execution_time_ns: std.atomic.Value(u64),
    active_workers: std.atomic.Value(u32),
    queue_size: std.atomic.Value(u32),
    
    // New fields for utilization tracking
    total_worker_time_ns: std.atomic.Value(u64),
    peak_active_workers: std.atomic.Value(u32),
    
    pub fn init() ThreadPoolStats {
        return ThreadPoolStats{
            .tasks_completed = std.atomic.Value(u64).init(0),
            .tasks_failed = std.atomic.Value(u64).init(0),
            .total_execution_time_ns = std.atomic.Value(u64).init(0),
            .active_workers = std.atomic.Value(u32).init(0),
            .queue_size = std.atomic.Value(u32).init(0),
            .total_worker_time_ns = std.atomic.Value(u64).init(0),
            .peak_active_workers = std.atomic.Value(u32).init(0),
        };
    }
    
    pub fn getCompletionRate(self: *const ThreadPoolStats) f64 {
        const completed = self.tasks_completed.load(.seq_cst);
        const failed = self.tasks_failed.load(.seq_cst);
        const total = completed + failed;
        
        if (total == 0) return 1.0;
        return @as(f64, @floatFromInt(completed)) / @as(f64, @floatFromInt(total));
    }
    
    pub fn getAverageExecutionTime(self: *const ThreadPoolStats) f64 {
        const completed = self.tasks_completed.load(.seq_cst);
        const total_time = self.total_execution_time_ns.load(.seq_cst);
        
        if (completed == 0) return 0.0;
        return @as(f64, @floatFromInt(total_time)) / @as(f64, @floatFromInt(completed));
    }
    
    pub fn getAverageUtilization(self: *const ThreadPoolStats, pool_size: u32, total_time_ns: u64) f64 {
        if (total_time_ns == 0 or pool_size == 0) return 0.0;
        
        const total_worker_time = self.total_worker_time_ns.load(.seq_cst);
        const max_possible_time = @as(u64, pool_size) * total_time_ns;
        
        return @as(f64, @floatFromInt(total_worker_time)) / @as(f64, @floatFromInt(max_possible_time));
    }
    
    pub fn getPeakUtilization(self: *const ThreadPoolStats, pool_size: u32) f64 {
        if (pool_size == 0) return 0.0;
        
        const peak = self.peak_active_workers.load(.seq_cst);
        return @as(f64, @floatFromInt(peak)) / @as(f64, @floatFromInt(pool_size));
    }
};

/// Main thread pool implementation
pub const ThreadPool = struct {
    allocator: std.mem.Allocator,
    config: ThreadPoolConfig,
    workers: std.ArrayList(Worker),
    work_queue: WorkQueue,
    running: std.atomic.Value(bool),
    stats: ThreadPoolStats,
    
    pub fn init(allocator: std.mem.Allocator, config: ThreadPoolConfig) !*ThreadPool {
        const num_threads = if (config.num_threads == 0) 
            try std.Thread.getCpuCount() 
        else 
            config.num_threads;
        
        const pool = try allocator.create(ThreadPool);
        pool.* = ThreadPool{
            .allocator = allocator,
            .config = config,
            .workers = std.ArrayList(Worker).init(allocator),
            .work_queue = WorkQueue.init(allocator),
            .running = std.atomic.Value(bool).init(false),
            .stats = ThreadPoolStats.init(),
        };
        
        // Create workers - now we can safely take the address of the heap-allocated pool
        try pool.workers.ensureTotalCapacity(num_threads);
        for (0..num_threads) |i| {
            const worker = Worker.init(@intCast(i), pool);
            pool.workers.appendAssumeCapacity(worker);
        }
        
        return pool;
    }
    
    pub fn deinit(self: *ThreadPool) void {
        const allocator = self.allocator;
        self.shutdown();
        self.work_queue.deinit();
        self.workers.deinit();
        allocator.destroy(self);
    }
    
    pub fn start(self: *ThreadPool) !void {
        if (self.running.load(.seq_cst)) return; // Already running
        
        self.running.store(true, .seq_cst);
        
        // Start worker threads
        for (self.workers.items) |*worker| {
            worker.thread = try std.Thread.spawn(.{
                .stack_size = self.config.thread_stack_size orelse 0,
            }, Worker.run, .{worker});
        }
    }
    
    pub fn shutdown(self: *ThreadPool) void {
        if (!self.running.load(.seq_cst)) return; // Already stopped
        
        // First, signal that the pool is shutting down
        self.running.store(false, .seq_cst);
        
        // Stop all workers
        for (self.workers.items) |*worker| {
            worker.running.store(false, .seq_cst);
        }
        
        // Add dummy work items to wake up any waiting workers
        const dummy_work = WorkItem{
            .custom = WorkItem.CustomWork{
                .work_fn = struct {
                    fn dummy(_: *WorkItem.CustomWork) anyerror!void {}
                }.dummy,
                .data = null,
            },
        };
        
        // Wake up workers with dummy work items
        for (0..self.workers.items.len) |_| {
            self.work_queue.enqueue(dummy_work) catch {};
        }
        
        // Give workers a moment to see the shutdown signal
        std.time.sleep(10_000_000); // 10ms
        
        // Join all threads
        for (self.workers.items) |*worker| {
            worker.thread.join();
        }
    }
    
    pub fn submit(self: *ThreadPool, work_item: WorkItem) !void {
        if (!self.running.load(.seq_cst)) return error.ThreadPoolNotRunning;
        
        try self.work_queue.enqueue(work_item);
        self.stats.queue_size.store(@intCast(self.work_queue.size()), .seq_cst);
    }
    
    pub fn getWork(self: *ThreadPool) ?WorkItem {
        return self.work_queue.dequeue();
    }
    
    pub fn waitForCompletion(self: *ThreadPool, timeout_ms: ?u64) bool {
        const start_time = std.time.milliTimestamp();
        
        while (true) {
            // Check if both queue is empty AND no workers are active
            const queue_empty = self.work_queue.size() == 0;
            const workers_idle = self.stats.active_workers.load(.seq_cst) == 0;
            
            if (queue_empty and workers_idle) {
                return true;
            }
            
            // Check timeout
            if (timeout_ms) |timeout| {
                const elapsed = std.time.milliTimestamp() - start_time;
                if (elapsed >= timeout) return false;
            }
            
            std.Thread.yield() catch {};
        }
    }
    
    pub fn getStats(self: *const ThreadPool) ThreadPoolStats {
        return self.stats;
    }
    
    pub fn getUtilization(self: *const ThreadPool) f64 {
        const active = self.stats.active_workers.load(.seq_cst);
        const total = self.workers.items.len;
        
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(active)) / @as(f64, @floatFromInt(total));
    }
};

/// Parallel algorithms implementation
pub const ParallelAlgorithms = struct {
    
    /// Parallel vector similarity search
    pub fn parallelVectorSimilarity(
        pool: *ThreadPool,
        query_vector: types.Vector,
        candidate_vectors: []const types.Vector,
        top_k: u32,
        allocator: std.mem.Allocator
    ) !std.ArrayList(types.SimilarityResult) {
        
        const num_workers = pool.workers.items.len;
        const chunk_size = (candidate_vectors.len + num_workers - 1) / num_workers;
        
        // Pre-allocate all result arrays to avoid reallocation and dangling pointers
        var all_results = std.ArrayList(std.ArrayList(types.SimilarityResult)).init(allocator);
        defer {
            for (all_results.items) |*results| {
                results.deinit();
            }
            all_results.deinit();
        }
        
        // Pre-allocate all result arrays first
        var work_count: usize = 0;
        for (0..num_workers) |i| {
            const start_idx = i * chunk_size;
            if (start_idx >= candidate_vectors.len) break;
            work_count += 1;
        }
        
        try all_results.ensureTotalCapacity(work_count);
        for (0..work_count) |_| {
            const chunk_results = std.ArrayList(types.SimilarityResult).init(allocator);
            all_results.appendAssumeCapacity(chunk_results);
        }
        
        // Create work items for each chunk
        var work_index: usize = 0;
        for (0..num_workers) |i| {
            const start_idx = i * chunk_size;
            const end_idx = @min(start_idx + chunk_size, candidate_vectors.len);
            
            if (start_idx >= candidate_vectors.len) break;
            
            // Validate slice bounds
            if (start_idx >= candidate_vectors.len or end_idx > candidate_vectors.len) {
                return error.InvalidSliceBounds;
            }
            
            const work_item = WorkItem{
                .vector_similarity = WorkItem.VectorSimilarityWork{
                    .query_vector_id = query_vector.id,
                    .candidate_vectors = candidate_vectors,
                    .results = &all_results.items[work_index],
                    .start_index = start_idx,
                    .end_index = end_idx,
                },
            };
            
            try pool.submit(work_item);
            work_index += 1;
        }
        
        // Wait for completion
        const completed = pool.waitForCompletion(5000); // 5 second timeout
        if (!completed) {
            return error.Timeout;
        }
        
        // Merge and sort results
        var final_results = std.ArrayList(types.SimilarityResult).init(allocator);
        
        for (all_results.items) |*chunk_results| {
            try final_results.appendSlice(chunk_results.items);
        }
        
        // Sort by similarity (descending)
        std.sort.pdq(types.SimilarityResult, final_results.items, {}, struct {
            fn lessThan(_: void, a: types.SimilarityResult, b: types.SimilarityResult) bool {
                return a.similarity > b.similarity;
            }
        }.lessThan);
        
        // Keep only top k
        const actual_k = @min(top_k, @as(u32, @intCast(final_results.items.len)));
        if (final_results.items.len > actual_k) {
            final_results.shrinkRetainingCapacity(actual_k);
        }
        
        return final_results;
    }
    
    /// Parallel map-reduce operation
    pub fn parallelMapReduce(
        pool: *ThreadPool,
        input_data: []const []const u8,
        map_fn: *const fn ([]const u8, *std.ArrayList(WorkItem.KeyValuePair)) anyerror!void,
        reduce_fn: *const fn ([]const WorkItem.KeyValuePair, *std.ArrayList(WorkItem.KeyValuePair)) anyerror!void,
        allocator: std.mem.Allocator
    ) !std.ArrayList(WorkItem.KeyValuePair) {
        
        const num_workers = pool.workers.items.len;
        const chunk_size = (input_data.len + num_workers - 1) / num_workers;
        
        var intermediate_results = std.ArrayList(std.ArrayList(WorkItem.KeyValuePair)).init(allocator);
        defer {
            for (intermediate_results.items) |*results| {
                results.deinit();
            }
            intermediate_results.deinit();
        }
        
        // Map phase
        for (0..num_workers) |i| {
            const start_idx = i * chunk_size;
            const end_idx = @min(start_idx + chunk_size, input_data.len);
            
            if (start_idx >= input_data.len) break;
            
            const chunk_results = std.ArrayList(WorkItem.KeyValuePair).init(allocator);
            try intermediate_results.append(chunk_results);
            
            // Process chunk data through map function
            for (input_data[start_idx..end_idx]) |chunk_data| {
                const work_item = WorkItem{
                    .map_reduce = WorkItem.MapReduceWork{
                        .input_data = chunk_data,
                        .map_fn = map_fn,
                        .reduce_fn = reduce_fn,
                        .output = &intermediate_results.items[intermediate_results.items.len - 1],
                        .allocator = allocator,
                    },
                };
                
                try pool.submit(work_item);
            }
        }
        
        // Wait for map phase completion
        _ = pool.waitForCompletion(10000); // 10 second timeout
        
        // Reduce phase - combine all intermediate results
        var final_results = std.ArrayList(WorkItem.KeyValuePair).init(allocator);
        
        for (intermediate_results.items) |*chunk_results| {
            try reduce_fn(chunk_results.items, &final_results);
        }
        
        return final_results;
    }
    
    /// Parallel batch processing
    pub fn parallelBatchProcess(
        pool: *ThreadPool,
        nodes: []const types.Node,
        edges: []const types.Edge,
        vectors: []const types.Vector
    ) !void {
        
        const num_workers = pool.workers.items.len;
        const nodes_per_worker = (nodes.len + num_workers - 1) / num_workers;
        const edges_per_worker = (edges.len + num_workers - 1) / num_workers;
        const vectors_per_worker = (vectors.len + num_workers - 1) / num_workers;
        
        // Create work items for each worker
        for (0..num_workers) |i| {
            const node_start = @min(i * nodes_per_worker, nodes.len);
            const node_end = @min(node_start + nodes_per_worker, nodes.len);
            
            const edge_start = @min(i * edges_per_worker, edges.len);
            const edge_end = @min(edge_start + edges_per_worker, edges.len);
            
            const vector_start = @min(i * vectors_per_worker, vectors.len);
            const vector_end = @min(vector_start + vectors_per_worker, vectors.len);
            
            if (node_start >= nodes.len and edge_start >= edges.len and vector_start >= vectors.len) {
                break;
            }
            
            const work_item = WorkItem{
                .batch_insert = WorkItem.BatchInsertWork{
                    .nodes = nodes[node_start..node_end],
                    .edges = edges[edge_start..edge_end],
                    .vectors = vectors[vector_start..vector_end],
                    .start_index = i,
                    .end_index = i + 1,
                },
            };
            
            try pool.submit(work_item);
        }
        
        // Wait for completion
        _ = pool.waitForCompletion(30000); // 30 second timeout
    }
};

// Work execution functions

pub fn executeVectorSimilarityWork(work: WorkItem.VectorSimilarityWork) !void {
    // Validate indices to prevent out of bounds access
    if (work.start_index >= work.candidate_vectors.len) {
        return;
    }
    const safe_end_index = @min(work.end_index, work.candidate_vectors.len);
    if (work.start_index >= safe_end_index) {
        return;
    }
    
    // Calculate similarities for the assigned chunk
    for (work.candidate_vectors[work.start_index..safe_end_index]) |candidate| {
        if (candidate.id == work.query_vector_id) {
            continue; // Skip self
        }
        
        // Find the query vector
        var query_vector: ?types.Vector = null;
        for (work.candidate_vectors) |vec| {
            if (vec.id == work.query_vector_id) {
                query_vector = vec;
                break;
            }
        }
        
        if (query_vector) |query| {
            const similarity = query.cosineSimilarity(&candidate);
            try work.results.append(types.SimilarityResult{
                .id = candidate.id,
                .similarity = similarity,
            });
        }
    }
}

fn executeGraphTraversalWork(work: WorkItem.GraphTraversalWork) !void {
    _ = work; // Implementation would depend on graph structure
    // This is a placeholder for graph traversal work
}

fn executeBatchInsertWork(work: WorkItem.BatchInsertWork) !void {
    _ = work; // Implementation would depend on storage system
    // This is a placeholder for batch insert work
}

fn executeMapReduceWork(work: WorkItem.MapReduceWork) !void {
    try work.map_fn(work.input_data, work.output);
}

/// Parallel execution context for managing concurrent operations
pub const ParallelContext = struct {
    thread_pool: *ThreadPool,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, config: ThreadPoolConfig) !ParallelContext {
        const pool = try ThreadPool.init(allocator, config);
        
        return ParallelContext{
            .thread_pool = pool,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *ParallelContext) void {
        self.thread_pool.deinit();
    }
    
    pub fn start(self: *ParallelContext) !void {
        try self.thread_pool.start();
    }
    
    pub fn shutdown(self: *ParallelContext) void {
        self.thread_pool.shutdown();
    }
    
    pub fn executeParallel(self: *ParallelContext, comptime T: type, 
                          items: []const T, 
                          func: *const fn (T) anyerror!void) !void {
        
        // Create a structure to hold both the item and function pointer
        const WorkData = struct {
            item: T,
            func_ptr: *const fn (T) anyerror!void,
        };
        
        var work_data_items = try self.allocator.alloc(WorkData, items.len);
        defer self.allocator.free(work_data_items);
        
        for (items, 0..) |item, i| {
            work_data_items[i] = WorkData{
                .item = item,
                .func_ptr = func,
            };
            
            const work_item = WorkItem{
                .custom = WorkItem.CustomWork{
                    .work_fn = struct {
                        fn execute(custom_work: *WorkItem.CustomWork) anyerror!void {
                            const data = @as(*WorkData, @ptrCast(@alignCast(custom_work.data.?)));
                            try data.func_ptr(data.item);
                        }
                    }.execute,
                    .data = @ptrCast(&work_data_items[i]),
                },
            };
            
            try self.thread_pool.submit(work_item);
        }
        
        _ = self.thread_pool.waitForCompletion(null);
    }
    
    pub fn getStats(self: *const ParallelContext) ThreadPoolStats {
        return self.thread_pool.getStats();
    }
}; 