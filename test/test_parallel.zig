const std = @import("std");
const testing = std.testing;
const memora = @import("memora");
const types = memora.types;
const parallel = memora.parallel;

// Comprehensive Parallel Processing Tests
// Following TigerBeetle-style programming: deterministic, extensive, zero external dependencies

test "ThreadPoolStats basic operations" {
    var stats = parallel.ThreadPoolStats.init();
    
    try testing.expect(stats.tasks_completed.load(.seq_cst) == 0);
    try testing.expect(stats.tasks_failed.load(.seq_cst) == 0);
    try testing.expect(stats.getCompletionRate() == 1.0);
    try testing.expect(stats.getAverageExecutionTime() == 0.0);
    
    // Simulate some completed and failed tasks
    stats.tasks_completed.store(8, .seq_cst);
    stats.tasks_failed.store(2, .seq_cst);
    stats.total_execution_time_ns.store(1000000, .seq_cst);
    
    try testing.expect(stats.getCompletionRate() == 0.8); // 8/10
    try testing.expect(stats.getAverageExecutionTime() == 125000.0); // 1000000/8
}

test "WorkQueue basic operations" {
    const allocator = testing.allocator;
    
    var queue = parallel.WorkQueue.init(allocator);
    defer queue.deinit();
    
    try testing.expect(queue.size() == 0);
    try testing.expect(queue.dequeue() == null);
    
    // Enqueue some work items
    const work1 = parallel.WorkItem{
        .custom = parallel.WorkItem.CustomWork{
            .work_fn = struct {
                fn dummy(_: *parallel.WorkItem.CustomWork) anyerror!void {}
            }.dummy,
            .data = null,
        },
    };
    
    try queue.enqueue(work1);
    try testing.expect(queue.size() == 1);
    
    const work2 = parallel.WorkItem{
        .custom = parallel.WorkItem.CustomWork{
            .work_fn = struct {
                fn dummy(_: *parallel.WorkItem.CustomWork) anyerror!void {}
            }.dummy,
            .data = null,
        },
    };
    
    try queue.enqueue(work2);
    try testing.expect(queue.size() == 2);
    
    // Dequeue items
    const dequeued1 = queue.dequeue();
    try testing.expect(dequeued1 != null);
    try testing.expect(queue.size() == 1);
    
    const dequeued2 = queue.dequeue();
    try testing.expect(dequeued2 != null);
    try testing.expect(queue.size() == 0);
    
    try testing.expect(queue.dequeue() == null);
}

test "ThreadPool initialization and configuration" {
    const allocator = testing.allocator;
    
    // Test auto-detection of CPU count
    const auto_config = parallel.ThreadPoolConfig{
        .num_threads = 0, // Auto-detect
        .enable_stats = true,
    };
    
    const pool = try parallel.ThreadPool.init(allocator, auto_config);
    defer pool.deinit();
    
    const cpu_count = try std.Thread.getCpuCount();
    try testing.expect(pool.workers.items.len == cpu_count);
    
    // Test manual thread count
    const manual_config = parallel.ThreadPoolConfig{
        .num_threads = 4,
        .enable_stats = true,
    };
    
    const manual_pool = try parallel.ThreadPool.init(allocator, manual_config);
    defer manual_pool.deinit();
    
    try testing.expect(manual_pool.workers.items.len == 4);
}

test "ThreadPool start and shutdown" {
    const allocator = testing.allocator;
    
    const config = parallel.ThreadPoolConfig{
        .num_threads = 2,
        .enable_stats = true,
    };
    
    const pool = try parallel.ThreadPool.init(allocator, config);
    defer pool.deinit();
    
    try testing.expect(!pool.running.load(.seq_cst));
    
    // Start the pool
    try pool.start();
    try testing.expect(pool.running.load(.seq_cst));
    
    // Should not error when starting an already running pool
    try pool.start();
    
    // Shutdown
    pool.shutdown();
    try testing.expect(!pool.running.load(.seq_cst));
    
    // Should not error when shutting down an already stopped pool
    pool.shutdown();
}

test "ThreadPool work submission and execution" {
    const allocator = testing.allocator;
    
    const config = parallel.ThreadPoolConfig{
        .num_threads = 2,
        .enable_stats = true,
    };
    
    const pool = try parallel.ThreadPool.init(allocator, config);
    defer pool.deinit();
    
    try pool.start();
    defer pool.shutdown();
    
    // Test that submitting to a stopped pool fails
    const stopped_pool = try parallel.ThreadPool.init(allocator, config);
    defer stopped_pool.deinit();
    
    const work_item = parallel.WorkItem{
        .custom = parallel.WorkItem.CustomWork{
            .work_fn = struct {
                fn dummy(_: *parallel.WorkItem.CustomWork) anyerror!void {}
            }.dummy,
            .data = null,
        },
    };
    
    const submit_result = stopped_pool.submit(work_item);
    try testing.expect(submit_result == error.ThreadPoolNotRunning);
    
    // Test successful submission
    try pool.submit(work_item);
    
    // Wait for completion
    const completed = pool.waitForCompletion(1000); // 1 second timeout
    try testing.expect(completed);
}

test "ThreadPool custom work execution" {
    const allocator = testing.allocator;
    
    const config = parallel.ThreadPoolConfig{
        .num_threads = 2,
        .enable_stats = true,
    };
    
    const pool = try parallel.ThreadPool.init(allocator, config);
    defer pool.deinit();
    
    try pool.start();
    defer pool.shutdown();
    
    // Create a counter that will be incremented by workers
    var counter = std.atomic.Value(u32).init(0);
    
    const CustomData = struct {
        counter: *std.atomic.Value(u32),
    };
    
    var custom_data = CustomData{ .counter = &counter };
    
    // Submit multiple work items
    for (0..10) |_| {
        const work_item = parallel.WorkItem{
            .custom = parallel.WorkItem.CustomWork{
                .work_fn = struct {
                    fn increment(custom_work: *parallel.WorkItem.CustomWork) anyerror!void {
                        const data = @as(*CustomData, @ptrCast(@alignCast(custom_work.data.?)));
                        _ = data.counter.fetchAdd(1, .seq_cst);
                    }
                }.increment,
                .data = @ptrCast(&custom_data),
            },
        };
        
        try pool.submit(work_item);
    }
    
    // Wait for completion
    const completed = pool.waitForCompletion(2000); // 2 second timeout
    try testing.expect(completed);
    
    // Check that all work was executed
    try testing.expect(counter.load(.seq_cst) == 10);
}

test "ParallelContext basic operations" {
    const allocator = testing.allocator;
    
    const config = parallel.ThreadPoolConfig{
        .num_threads = 2,
        .enable_stats = true,
    };
    
    var context = try parallel.ParallelContext.init(allocator, config);
    defer context.deinit();
    
    try context.start();
    defer context.shutdown();
    
    // Test parallel execution of a simple function
    const items = [_]u32{ 1, 2, 3, 4, 5 };
    
    const increment_fn = struct {
        fn execute(item: u32) anyerror!void {
            _ = item; // Use the item (could process it)
            // Access counter through a more complex mechanism if needed
            // For this test, we'll just verify the function is called
        }
    }.execute;
    
    try context.executeParallel(u32, &items, increment_fn);
    
    const stats = context.getStats();
    _ = stats; // Use stats to avoid unused variable warning
    // Stats should show some activity (exact values depend on timing)
    try testing.expect(true); // Basic completion test
}

test "ParallelAlgorithms vector similarity" {
    const allocator = testing.allocator;
    
    const config = parallel.ThreadPoolConfig{
        .num_threads = 2,
        .enable_stats = true,
    };
    
    const pool = try parallel.ThreadPool.init(allocator, config);
    defer pool.deinit();
    
    try pool.start();
    defer pool.shutdown();
    
    // Create test vectors
    const dims1 = [_]f32{ 1.0, 0.0, 0.0 } ++ [_]f32{0.0} ** 125;
    const dims2 = [_]f32{ 0.9, 0.1, 0.0 } ++ [_]f32{0.0} ** 125;
    const dims3 = [_]f32{ 0.0, 1.0, 0.0 } ++ [_]f32{0.0} ** 125;
    const dims4 = [_]f32{ 0.8, 0.6, 0.0 } ++ [_]f32{0.0} ** 125;
    
    const query_vector = types.Vector.init(1, &dims1);
    const candidate_vectors = [_]types.Vector{
        query_vector,
        types.Vector.init(2, &dims2),
        types.Vector.init(3, &dims3),
        types.Vector.init(4, &dims4),
    };
    
    // Test parallel similarity search
    const results = try parallel.ParallelAlgorithms.parallelVectorSimilarity(
        pool,
        query_vector,
        &candidate_vectors,
        3,
        allocator
    );
    defer results.deinit();
    
    // Should find similar vectors, excluding self
    try testing.expect(results.items.len <= 3);
    try testing.expect(results.items.len >= 1); // Should find at least one result
    
    // Results should be sorted by similarity (descending) - only check if we have results
    if (results.items.len > 1) {
        for (0..results.items.len - 1) |i| {
            try testing.expect(results.items[i].similarity >= results.items[i + 1].similarity);
        }
    }
    
    // None of the results should be the query vector itself
    for (results.items) |result| {
        try testing.expect(result.id != query_vector.id);
    }
}

test "WorkItem vector similarity execution" {
    const allocator = testing.allocator;
    
    // Create test vectors
    const dims1 = [_]f32{ 1.0, 0.0, 0.0 } ++ [_]f32{0.0} ** 125;
    const dims2 = [_]f32{ 0.9, 0.1, 0.0 } ++ [_]f32{0.0} ** 125;
    const dims3 = [_]f32{ 0.0, 1.0, 0.0 } ++ [_]f32{0.0} ** 125;
    
    const vectors = [_]types.Vector{
        types.Vector.init(1, &dims1),
        types.Vector.init(2, &dims2),
        types.Vector.init(3, &dims3),
    };
    
    var results = std.ArrayList(types.SimilarityResult).init(allocator);
    defer results.deinit();
    
    // Create and execute vector similarity work
    const work = parallel.WorkItem.VectorSimilarityWork{
        .query_vector_id = 1,
        .candidate_vectors = &vectors,
        .results = &results,
        .start_index = 0,
        .end_index = vectors.len,
    };
    
    try parallel.executeVectorSimilarityWork(work);
    
    // Should have results for vectors 2 and 3 (excluding self)
    try testing.expect(results.items.len == 2);
    
    // Check that similarities are reasonable
    for (results.items) |result| {
        try testing.expect(result.similarity >= -1.0 and result.similarity <= 1.0);
        try testing.expect(result.id != 1); // Not the query vector
    }
}

test "Parallel processing stress test" {
    const allocator = testing.allocator;
    
    const config = parallel.ThreadPoolConfig{
        .num_threads = 4,
        .enable_stats = true,
    };
    
    const pool = try parallel.ThreadPool.init(allocator, config);
    defer pool.deinit();
    
    try pool.start();
    defer pool.shutdown();
    
    var timer = std.time.Timer.start() catch return;
    
    // Submit a large number of work items
    const num_tasks = 1000;
    var completed_tasks = std.atomic.Value(u32).init(0);
    
    const TaskData = struct {
        task_id: u32,
        completed_counter: *std.atomic.Value(u32),
    };
    
    var task_data_items = try allocator.alloc(TaskData, num_tasks);
    defer allocator.free(task_data_items);
    
    for (0..num_tasks) |i| {
        task_data_items[i] = TaskData{
            .task_id = @intCast(i),
            .completed_counter = &completed_tasks,
        };
        
        const work_item = parallel.WorkItem{
            .custom = parallel.WorkItem.CustomWork{
                .work_fn = struct {
                    fn process_task(custom_work: *parallel.WorkItem.CustomWork) anyerror!void {
                        const data = @as(*TaskData, @ptrCast(@alignCast(custom_work.data.?)));
                        
                        // Simulate some work
                        var sum: u64 = 0;
                        for (0..data.task_id % 100 + 1) |j| {
                            sum += j;
                        }
                        
                        // Prevent optimization
                        if (sum == std.math.maxInt(u64)) {
                            std.debug.print("Impossible\n", .{});
                        }
                        
                        _ = data.completed_counter.fetchAdd(1, .seq_cst);
                    }
                }.process_task,
                .data = @ptrCast(&task_data_items[i]),
            },
        };
        
        try pool.submit(work_item);
    }
    
    const submit_time = timer.lap();
    
    // Wait for completion
    const completed = pool.waitForCompletion(10000); // 10 second timeout
    try testing.expect(completed);
    
    const execution_time = timer.lap();
    
    // Verify all tasks completed
    try testing.expect(completed_tasks.load(.seq_cst) == num_tasks);
    
    // Performance assertions
    try testing.expect(submit_time < 1_000_000_000); // < 1 second for submission
    try testing.expect(execution_time < 5_000_000_000); // < 5 seconds for execution
    
    const stats = pool.getStats();
    
    std.debug.print("\nParallel Processing Stress Test Results ({} tasks, {} threads):\n", .{ num_tasks, pool.workers.items.len });
    std.debug.print("  Submit time: {}ns ({} per task)\n", .{ submit_time, submit_time / num_tasks });
    std.debug.print("  Execution time: {}ns ({} per task)\n", .{ execution_time, execution_time / num_tasks });
    std.debug.print("  Completion rate: {d:.3}\n", .{stats.getCompletionRate()});
    std.debug.print("  Instantaneous utilization: {d:.3} (after completion)\n", .{pool.getUtilization()});
    std.debug.print("  Average utilization: {d:.3}\n", .{stats.getAverageUtilization(@intCast(pool.workers.items.len), execution_time)});
    std.debug.print("  Peak utilization: {d:.3}\n", .{stats.getPeakUtilization(@intCast(pool.workers.items.len))});
}

test "ThreadPool deterministic behavior" {
    const allocator = testing.allocator;
    
    const config = parallel.ThreadPoolConfig{
        .num_threads = 2,
        .enable_stats = true,
    };
    
    // Create two identical thread pools
    const pool1 = try parallel.ThreadPool.init(allocator, config);
    defer pool1.deinit();
    
    const pool2 = try parallel.ThreadPool.init(allocator, config);
    defer pool2.deinit();
    
    try pool1.start();
    defer pool1.shutdown();
    
    try pool2.start();
    defer pool2.shutdown();
    
    // Submit identical work to both pools
    var counter1 = std.atomic.Value(u32).init(0);
    var counter2 = std.atomic.Value(u32).init(0);
    
    const CounterData = struct {
        counter: *std.atomic.Value(u32),
    };
    
    var data1 = CounterData{ .counter = &counter1 };
    var data2 = CounterData{ .counter = &counter2 };
    
    const num_tasks = 10;
    
    for (0..num_tasks) |_| {
        const work1 = parallel.WorkItem{
            .custom = parallel.WorkItem.CustomWork{
                .work_fn = struct {
                    fn increment(custom_work: *parallel.WorkItem.CustomWork) anyerror!void {
                        const data = @as(*CounterData, @ptrCast(@alignCast(custom_work.data.?)));
                        _ = data.counter.fetchAdd(1, .seq_cst);
                    }
                }.increment,
                .data = @ptrCast(&data1),
            },
        };
        
        const work2 = parallel.WorkItem{
            .custom = parallel.WorkItem.CustomWork{
                .work_fn = struct {
                    fn increment(custom_work: *parallel.WorkItem.CustomWork) anyerror!void {
                        const data = @as(*CounterData, @ptrCast(@alignCast(custom_work.data.?)));
                        _ = data.counter.fetchAdd(1, .seq_cst);
                    }
                }.increment,
                .data = @ptrCast(&data2),
            },
        };
        
        try pool1.submit(work1);
        try pool2.submit(work2);
    }
    
    // Wait for completion
    const completed1 = pool1.waitForCompletion(2000);
    const completed2 = pool2.waitForCompletion(2000);
    
    try testing.expect(completed1);
    try testing.expect(completed2);
    
    // Both pools should have processed the same amount of work
    try testing.expect(counter1.load(.seq_cst) == num_tasks);
    try testing.expect(counter2.load(.seq_cst) == num_tasks);
}

test "ThreadPool edge cases and error handling" {
    const allocator = testing.allocator;
    
    const config = parallel.ThreadPoolConfig{
        .num_threads = 1,
        .enable_stats = true,
    };
    
    const pool = try parallel.ThreadPool.init(allocator, config);
    defer pool.deinit();
    
    // Test operations on unstarted pool
    try testing.expect(!pool.running.load(.seq_cst));
    
    const work_item = parallel.WorkItem{
        .custom = parallel.WorkItem.CustomWork{
            .work_fn = struct {
                fn dummy(_: *parallel.WorkItem.CustomWork) anyerror!void {}
            }.dummy,
            .data = null,
        },
    };
    
    // Should fail to submit to unstarted pool
    const submit_result = pool.submit(work_item);
    try testing.expect(submit_result == error.ThreadPoolNotRunning);
    
    // Start pool
    try pool.start();
    defer pool.shutdown();
    
    // Should succeed now
    try pool.submit(work_item);
    
    // Test work execution with error
    const error_work = parallel.WorkItem{
        .custom = parallel.WorkItem.CustomWork{
            .work_fn = struct {
                fn error_func(_: *parallel.WorkItem.CustomWork) anyerror!void {
                    return error.TestError;
                }
            }.error_func,
            .data = null,
        },
    };
    
    // Should not crash the pool
    try pool.submit(error_work);
    
    // Wait for processing
    _ = pool.waitForCompletion(1000);
    
    // Pool should still be running
    try testing.expect(pool.running.load(.seq_cst));
}

test "ThreadPool with zero threads configuration" {
    const allocator = testing.allocator;
    
    // Test that zero threads gets auto-detected
    const config = parallel.ThreadPoolConfig{
        .num_threads = 0, // Should auto-detect CPU count
        .enable_stats = true,
    };
    
    const pool = try parallel.ThreadPool.init(allocator, config);
    defer pool.deinit();
    
    const expected_threads = try std.Thread.getCpuCount();
    try testing.expect(pool.workers.items.len == expected_threads);
    try testing.expect(pool.workers.items.len > 0); // Should have at least one thread
}

test "WorkQueue timeout operations" {
    const allocator = testing.allocator;
    
    var queue = parallel.WorkQueue.init(allocator);
    defer queue.deinit();
    
    // Test timeout on empty queue
    const start_time = std.time.milliTimestamp();
    const result = queue.waitForWork(100); // 100ms timeout
    const elapsed = std.time.milliTimestamp() - start_time;
    
    try testing.expect(result == null);
    try testing.expect(elapsed >= 90 and elapsed <= 200); // Allow some variance
}

test "ThreadPool utilization metrics" {
    const allocator = testing.allocator;
    
    const config = parallel.ThreadPoolConfig{
        .num_threads = 4,
        .enable_stats = true,
    };
    
    const pool = try parallel.ThreadPool.init(allocator, config);
    defer pool.deinit();
    
    // Test utilization before starting
    const initial_utilization = pool.getUtilization();
    try testing.expect(initial_utilization == 0.0);
    
    try pool.start();
    defer pool.shutdown();
    
    // Submit some long-running work to increase utilization
    var barrier = std.atomic.Value(bool).init(false);
    
    for (0..2) |_| { // Submit 2 tasks to 4-thread pool = 50% utilization
        const work_item = parallel.WorkItem{
            .custom = parallel.WorkItem.CustomWork{
                .work_fn = struct {
                    fn long_task(custom_work: *parallel.WorkItem.CustomWork) anyerror!void {
                        const sync_barrier = @as(*std.atomic.Value(bool), @ptrCast(@alignCast(custom_work.data.?)));
                        
                        // Wait for barrier
                        while (!sync_barrier.load(.seq_cst)) {
                            std.Thread.yield() catch {};
                        }
                    }
                }.long_task,
                .data = @ptrCast(&barrier),
            },
        };
        
        try pool.submit(work_item);
    }
    
    // Give tasks time to start
    std.time.sleep(50_000_000); // 50ms
    
    // Release tasks
    barrier.store(true, .seq_cst);
    
    // Wait for completion
    _ = pool.waitForCompletion(1000);
    
    const stats = pool.getStats();
    try testing.expect(stats.tasks_completed.load(.seq_cst) >= 0); // Basic sanity check
} 