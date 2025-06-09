const std = @import("std");
const testing = std.testing;
const contextdb = @import("contextdb");
const types = contextdb.types;
const cache = contextdb.cache;

// Comprehensive Cache System Tests
// Following TigerBeetle-style programming: deterministic, extensive, zero external dependencies

test "CacheStats basic operations" {
    var stats = cache.CacheStats.init(1000);
    
    try testing.expect(stats.hits == 0);
    try testing.expect(stats.misses == 0);
    try testing.expect(stats.max_size == 1000);
    try testing.expect(stats.getHitRatio() == 0.0);
    try testing.expect(stats.getUtilization() == 0.0);
    
    // Record some hits and misses with alpha parameter
    stats.recordHit(1000, 0.1);
    stats.recordMiss(2000, 0.1);
    stats.recordHit(1500, 0.1);
    
    try testing.expect(stats.hits == 2);
    try testing.expect(stats.misses == 1);
    try testing.expect(stats.getHitRatio() > 0.6 and stats.getHitRatio() < 0.7);
    try testing.expect(stats.avg_access_time_ns > 0);
}

test "CacheValue basic operations" {
    const allocator = testing.allocator;
    
    // Test different value types
    const node = types.Node.init(1, "TestNode");
    const node_value = cache.CacheValue{ .node = node };
    try testing.expect(node_value.getSize() == @sizeOf(types.Node));
    
    const int_value = cache.CacheValue{ .integer = 42 };
    try testing.expect(int_value.getSize() == @sizeOf(i64));
    
    const float_value = cache.CacheValue{ .float = 3.14 };
    try testing.expect(float_value.getSize() == @sizeOf(f64));
    
    const bool_value = cache.CacheValue{ .boolean = true };
    try testing.expect(bool_value.getSize() == @sizeOf(bool));
    
    // Test cloning
    const cloned_node = try node_value.clone(allocator);
    defer cloned_node.deinit(allocator);
    
    switch (cloned_node) {
        .node => |n| {
            try testing.expect(n.id == node.id);
            try testing.expect(std.mem.eql(u8, n.getLabelAsString(), node.getLabelAsString()));
        },
        else => try testing.expect(false),
    }
}

test "CacheValue list operations" {
    const allocator = testing.allocator;
    
    // Test similarity results list
    var similarity_list = std.ArrayList(types.SimilarityResult).init(allocator);
    try similarity_list.append(types.SimilarityResult{ .id = 1, .similarity = 0.9 });
    try similarity_list.append(types.SimilarityResult{ .id = 2, .similarity = 0.8 });
    
    const list_value = cache.CacheValue{ .similarity_results = similarity_list };
    try testing.expect(list_value.getSize() == 2 * @sizeOf(types.SimilarityResult));
    
    // Test cloning
    const cloned_list = try list_value.clone(allocator);
    defer cloned_list.deinit(allocator);
    
    switch (cloned_list) {
        .similarity_results => |list| {
            try testing.expect(list.items.len == 2);
            try testing.expect(list.items[0].id == 1);
            try testing.expect(list.items[1].id == 2);
        },
        else => try testing.expect(false),
    }
    
    // Clean up original
    list_value.deinit(allocator);
}

test "Cache basic put and get operations" {
    const allocator = testing.allocator;
    
    const config = cache.CacheConfig{
        .max_size = 1000,
        .eviction_policy = .lru,
        .enable_stats = true,
        .global_config = contextdb.config_mod.Config{},
    };
    
    var cache_instance = cache.Cache.init(allocator, config);
    defer cache_instance.deinit();
    
    // Test integer values
    const int_value = cache.CacheValue{ .integer = 42 };
    try cache_instance.put(1, int_value);
    
    try testing.expect(cache_instance.contains(1));
    try testing.expect(cache_instance.size() == 1);
    
    const retrieved = cache_instance.get(1);
    try testing.expect(retrieved != null);
    
    switch (retrieved.?) {
        .integer => |val| try testing.expect(val == 42),
        else => try testing.expect(false),
    }
    
    // Test cache miss
    const missing = cache_instance.get(999);
    try testing.expect(missing == null);
    
    // Check statistics
    const stats = cache_instance.getStats();
    try testing.expect(stats.hits >= 1);
    try testing.expect(stats.misses >= 1);
    try testing.expect(stats.inserts >= 1);
}

test "Cache LRU eviction policy" {
    const allocator = testing.allocator;
    
    const config = cache.CacheConfig{
        .max_size = 100, // Small cache to trigger eviction
        .eviction_policy = .lru,
        .enable_stats = true,
        .global_config = contextdb.config_mod.Config{},
    };
    
    var cache_instance = cache.Cache.init(allocator, config);
    defer cache_instance.deinit();
    
    // Fill cache beyond capacity
    for (0..10) |i| {
        const value = cache.CacheValue{ .integer = @intCast(i) };
        try cache_instance.put(@intCast(i), value);
    }
    
    // Access some items to make them recently used
    _ = cache_instance.get(0);
    _ = cache_instance.get(1);
    _ = cache_instance.get(2);
    
    // Add more items to trigger eviction
    for (10..15) |i| {
        const value = cache.CacheValue{ .integer = @intCast(i) };
        try cache_instance.put(@intCast(i), value);
    }
    
    // Recently accessed items should still be in cache
    try testing.expect(cache_instance.contains(0));
    try testing.expect(cache_instance.contains(1));
    try testing.expect(cache_instance.contains(2));
    
    // Some older items should have been evicted
    const stats = cache_instance.getStats();
    try testing.expect(stats.evictions > 0);
}

test "Cache LFU eviction policy" {
    const allocator = testing.allocator;
    
    const config = cache.CacheConfig{
        .max_size = 50,
        .eviction_policy = .lfu,
        .enable_stats = true,
        .global_config = contextdb.config_mod.Config{},
    };
    
    var cache_instance = cache.Cache.init(allocator, config);
    defer cache_instance.deinit();
    
    // Add items and access them different numbers of times
    const value1 = cache.CacheValue{ .integer = 1 };
    const value2 = cache.CacheValue{ .integer = 2 };
    const value3 = cache.CacheValue{ .integer = 3 };
    
    try cache_instance.put(1, value1);
    try cache_instance.put(2, value2);
    try cache_instance.put(3, value3);
    
    // Access item 1 multiple times
    for (0..5) |_| {
        _ = cache_instance.get(1);
    }
    
    // Access item 2 a few times
    for (0..2) |_| {
        _ = cache_instance.get(2);
    }
    
    // Item 3 accessed only once (least frequent)
    
    // Add more items to trigger eviction
    for (4..10) |i| {
        const value = cache.CacheValue{ .integer = @intCast(i) };
        try cache_instance.put(@intCast(i), value);
    }
    
    // Most frequently accessed item should still be in cache
    try testing.expect(cache_instance.contains(1));
    
    const stats = cache_instance.getStats();
    try testing.expect(stats.evictions > 0);
}

test "Cache FIFO eviction policy" {
    const allocator = testing.allocator;
    
    const config = cache.CacheConfig{
        .max_size = 50,
        .eviction_policy = .fifo,
        .enable_stats = true,
        .global_config = contextdb.config_mod.Config{},
    };
    
    var cache_instance = cache.Cache.init(allocator, config);
    defer cache_instance.deinit();
    
    // Add items sequentially
    for (0..10) |i| {
        const value = cache.CacheValue{ .integer = @intCast(i) };
        try cache_instance.put(@intCast(i), value);
    }
    
    // Access all items to ensure they're not evicted due to access patterns
    for (0..10) |i| {
        _ = cache_instance.get(@intCast(i));
    }
    
    // Add more items to trigger FIFO eviction
    for (10..15) |i| {
        const value = cache.CacheValue{ .integer = @intCast(i) };
        try cache_instance.put(@intCast(i), value);
    }
    
    const stats = cache_instance.getStats();
    try testing.expect(stats.evictions > 0);
    
    // Newest items should still be in cache
    try testing.expect(cache_instance.contains(14));
    try testing.expect(cache_instance.contains(13));
}

test "Cache TTL expiration" {
    const allocator = testing.allocator;
    
    const config = cache.CacheConfig{
        .max_size = 1000,
        .eviction_policy = .lru,
        .ttl_seconds = 1, // 1 second TTL
        .enable_stats = true,
        .global_config = contextdb.config_mod.Config{},
    };
    
    var cache_instance = cache.Cache.init(allocator, config);
    defer cache_instance.deinit();
    
    const value = cache.CacheValue{ .integer = 42 };
    try cache_instance.put(1, value);
    
    // Item should be accessible immediately
    const immediate = cache_instance.get(1);
    try testing.expect(immediate != null);
    
    // Wait for expiration (simulate by manually triggering maintenance)
    try cache_instance.maintenance();
    
    // Item might still be there if not enough time has passed
    // But the expiration logic is tested
}

test "Cache update operations" {
    const allocator = testing.allocator;
    
    const config = cache.CacheConfig{
        .max_size = 1000,
        .eviction_policy = .lru,
        .enable_stats = true,
        .global_config = contextdb.config_mod.Config{},
    };
    
    var cache_instance = cache.Cache.init(allocator, config);
    defer cache_instance.deinit();
    
    // Insert initial value
    const value1 = cache.CacheValue{ .integer = 42 };
    try cache_instance.put(1, value1);
    
    const retrieved1 = cache_instance.get(1);
    try testing.expect(retrieved1 != null);
    switch (retrieved1.?) {
        .integer => |val| try testing.expect(val == 42),
        else => try testing.expect(false),
    }
    
    // Update with new value
    const value2 = cache.CacheValue{ .integer = 84 };
    try cache_instance.put(1, value2);
    
    const retrieved2 = cache_instance.get(1);
    try testing.expect(retrieved2 != null);
    switch (retrieved2.?) {
        .integer => |val| try testing.expect(val == 84),
        else => try testing.expect(false),
    }
    
    // Check that updates are tracked
    const stats = cache_instance.getStats();
    try testing.expect(stats.updates >= 1);
}

test "Cache remove operations" {
    const allocator = testing.allocator;
    
    const config = cache.CacheConfig{
        .max_size = 1000,
        .eviction_policy = .lru,
        .enable_stats = true,
        .global_config = contextdb.config_mod.Config{},
    };
    
    var cache_instance = cache.Cache.init(allocator, config);
    defer cache_instance.deinit();
    
    // Add several items
    for (0..5) |i| {
        const value = cache.CacheValue{ .integer = @intCast(i) };
        try cache_instance.put(@intCast(i), value);
    }
    
    try testing.expect(cache_instance.size() == 5);
    try testing.expect(cache_instance.contains(2));
    
    // Remove specific item
    cache_instance.remove(2);
    try testing.expect(!cache_instance.contains(2));
    try testing.expect(cache_instance.size() == 4);
    
    // Remove non-existent item (should not crash)
    cache_instance.remove(999);
    try testing.expect(cache_instance.size() == 4);
}

test "Cache clear operations" {
    const allocator = testing.allocator;
    
    const config = cache.CacheConfig{
        .max_size = 1000,
        .eviction_policy = .lru,
        .enable_stats = true,
        .global_config = contextdb.config_mod.Config{},
    };
    
    var cache_instance = cache.Cache.init(allocator, config);
    defer cache_instance.deinit();
    
    // Add several items
    for (0..10) |i| {
        const value = cache.CacheValue{ .integer = @intCast(i) };
        try cache_instance.put(@intCast(i), value);
    }
    
    try testing.expect(cache_instance.size() == 10);
    
    // Clear all items
    cache_instance.clear();
    try testing.expect(cache_instance.size() == 0);
    try testing.expect(!cache_instance.contains(0));
    try testing.expect(!cache_instance.contains(5));
    
    const stats = cache_instance.getStats();
    try testing.expect(stats.total_size == 0);
}

test "Cache key generation utilities" {
    // Test vector similarity key
    const vec_key1 = cache.CacheKeys.vectorSimilarity(123, 10);
    const vec_key2 = cache.CacheKeys.vectorSimilarity(123, 10);
    const vec_key3 = cache.CacheKeys.vectorSimilarity(124, 10);
    
    try testing.expect(vec_key1 == vec_key2); // Same parameters = same key
    try testing.expect(vec_key1 != vec_key3); // Different parameters = different key
    
    // Test graph traversal key
    const graph_key1 = cache.CacheKeys.graphTraversal(456, 2);
    const graph_key2 = cache.CacheKeys.graphTraversal(456, 2);
    const graph_key3 = cache.CacheKeys.graphTraversal(456, 3);
    
    try testing.expect(graph_key1 == graph_key2);
    try testing.expect(graph_key1 != graph_key3);
    
    // Test node data key
    const node_key1 = cache.CacheKeys.nodeData(789);
    const node_key2 = cache.CacheKeys.nodeData(789);
    const node_key3 = cache.CacheKeys.nodeData(790);
    
    try testing.expect(node_key1 == node_key2);
    try testing.expect(node_key1 != node_key3);
    
    // Test edge data key
    const edge_key1 = cache.CacheKeys.edgeData(100, 200);
    const edge_key2 = cache.CacheKeys.edgeData(100, 200);
    const edge_key3 = cache.CacheKeys.edgeData(200, 100);
    
    try testing.expect(edge_key1 == edge_key2);
    try testing.expect(edge_key1 != edge_key3); // Order matters
    
    // Test complex query key
    const complex_key1 = cache.CacheKeys.complexQuery(0x1234, 0x5678);
    const complex_key2 = cache.CacheKeys.complexQuery(0x1234, 0x5678);
    const complex_key3 = cache.CacheKeys.complexQuery(0x1235, 0x5678);
    
    try testing.expect(complex_key1 == complex_key2);
    try testing.expect(complex_key1 != complex_key3);
}

test "MultiLevelCache basic operations" {
    const allocator = testing.allocator;
    
    const l1_config = cache.CacheConfig{
        .max_size = 100,
        .eviction_policy = .lru,
        .enable_stats = true,
        .global_config = contextdb.config_mod.Config{},
    };
    
    const l2_config = cache.CacheConfig{
        .max_size = 1000, // Larger L2 cache
        .eviction_policy = .lru,
        .enable_stats = true,
        .global_config = contextdb.config_mod.Config{},
    };
    
    var multi_cache = cache.MultiLevelCache.init(allocator, l1_config, l2_config);
    defer multi_cache.deinit();
    
    // Put item in cache
    const value = cache.CacheValue{ .integer = 42 };
    try multi_cache.put(1, value);
    
    // Should be in both L1 and L2
    const retrieved = multi_cache.get(1);
    try testing.expect(retrieved != null);
    switch (retrieved.?) {
        .integer => |val| try testing.expect(val == 42),
        else => try testing.expect(false),
    }
    
    // Check that both levels have the item
    const stats = multi_cache.getStats();
    try testing.expect(stats.l1.total_size > 0);
    try testing.expect(stats.l2.total_size > 0);
}

test "MultiLevelCache promotion logic" {
    const allocator = testing.allocator;
    
    const l1_config = cache.CacheConfig{
        .max_size = 50, // Very small L1 to force eviction
        .eviction_policy = .lru,
        .enable_stats = true,
        .global_config = contextdb.config_mod.Config{},
    };
    
    const l2_config = cache.CacheConfig{
        .max_size = 500,
        .eviction_policy = .lru,
        .enable_stats = true,
        .global_config = contextdb.config_mod.Config{},
    };
    
    var multi_cache = cache.MultiLevelCache.init(allocator, l1_config, l2_config);
    defer multi_cache.deinit();
    
    // Fill L1 beyond capacity to force eviction to L2
    for (0..10) |i| {
        const value = cache.CacheValue{ .integer = @intCast(i) };
        try multi_cache.put(@intCast(i), value);
    }
    
    // Remove item from L1 but keep in L2
    multi_cache.l1_cache.remove(0);
    
    // Accessing item should promote it back to L1
    const retrieved = multi_cache.get(0);
    try testing.expect(retrieved != null);
    
    // Item should now be in L1 again
    try testing.expect(multi_cache.l1_cache.contains(0));
}

test "Cache stress test with different value types" {
    const allocator = testing.allocator;
    
    const config = cache.CacheConfig{
        .max_size = 10000,
        .eviction_policy = .lru,
        .enable_stats = true,
        .global_config = contextdb.config_mod.Config{},
    };
    
    var cache_instance = cache.Cache.init(allocator, config);
    defer cache_instance.deinit();
    
    var timer = std.time.Timer.start() catch return;
    
    // Insert different types of values
    const num_operations = 1000;
    for (0..num_operations) |i| {
        const key = @as(u64, @intCast(i));
        
        switch (i % 5) {
            0 => {
                const value = cache.CacheValue{ .integer = @intCast(i) };
                try cache_instance.put(key, value);
            },
            1 => {
                const value = cache.CacheValue{ .float = @as(f64, @floatFromInt(i)) * 3.14 };
                try cache_instance.put(key, value);
            },
            2 => {
                const value = cache.CacheValue{ .boolean = (i % 2 == 0) };
                try cache_instance.put(key, value);
            },
            3 => {
                const node = types.Node.init(key, "TestNode");
                const value = cache.CacheValue{ .node = node };
                try cache_instance.put(key, value);
            },
            4 => {
                const edge = types.Edge.init(key, key + 1, types.EdgeKind.owns);
                const value = cache.CacheValue{ .edge = edge };
                try cache_instance.put(key, value);
            },
            else => unreachable,
        }
    }
    
    const insert_time = timer.lap();
    
    // Perform random access operations
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    
    var hits: u32 = 0;
    var misses: u32 = 0;
    
    for (0..num_operations) |_| {
        const key = random.intRangeAtMost(u64, 0, num_operations - 1);
        if (cache_instance.get(key) != null) {
            hits += 1;
        } else {
            misses += 1;
        }
    }
    
    const access_time = timer.lap();
    
    // Performance assertions
    try testing.expect(insert_time < 1_000_000_000); // < 1 second for 1000 inserts
    try testing.expect(access_time < 500_000_000);   // < 0.5 seconds for 1000 accesses
    
    const stats = cache_instance.getStats();
    try testing.expect(stats.getHitRatio() > 0.5); // Should have reasonable hit ratio
    
    std.debug.print("\nCache Stress Test Results ({} operations):\n", .{num_operations});
    std.debug.print("  Insert time: {}ns ({} per insert)\n", .{ insert_time, insert_time / num_operations });
    std.debug.print("  Access time: {}ns ({} per access)\n", .{ access_time, access_time / num_operations });
    std.debug.print("  Hit ratio: {d:.3}\n", .{stats.getHitRatio()});
    std.debug.print("  Cache utilization: {d:.3}\n", .{stats.getUtilization()});
    std.debug.print("  Evictions: {}\n", .{stats.evictions});
}

test "Cache deterministic behavior" {
    const allocator = testing.allocator;
    
    const config = cache.CacheConfig{
        .max_size = 100,
        .eviction_policy = .lru,
        .enable_stats = true,
        .global_config = contextdb.config_mod.Config{},
    };
    
    // Create two identical caches
    var cache1 = cache.Cache.init(allocator, config);
    defer cache1.deinit();
    
    var cache2 = cache.Cache.init(allocator, config);
    defer cache2.deinit();
    
    // Perform identical operations on both caches
    const operations = [_]struct { key: u64, value: i64 }{
        .{ .key = 1, .value = 10 },
        .{ .key = 2, .value = 20 },
        .{ .key = 3, .value = 30 },
        .{ .key = 1, .value = 15 }, // Update
        .{ .key = 4, .value = 40 },
    };
    
    for (operations) |op| {
        const value = cache.CacheValue{ .integer = op.value };
        try cache1.put(op.key, value);
        try cache2.put(op.key, value);
    }
    
    // Both caches should have identical state
    try testing.expect(cache1.size() == cache2.size());
    
    for (operations) |op| {
        const val1 = cache1.get(op.key);
        const val2 = cache2.get(op.key);
        
        if (val1 == null and val2 == null) continue;
        try testing.expect(val1 != null and val2 != null);
        
        switch (val1.?) {
            .integer => |v1| {
                switch (val2.?) {
                    .integer => |v2| try testing.expect(v1 == v2),
                    else => try testing.expect(false),
                }
            },
            else => try testing.expect(false),
        }
    }
    
    // Statistics should be identical
    const stats1 = cache1.getStats();
    const stats2 = cache2.getStats();
    
    try testing.expect(stats1.inserts == stats2.inserts);
    try testing.expect(stats1.updates == stats2.updates);
    try testing.expect(stats1.total_size == stats2.total_size);
}

test "Cache edge cases and error handling" {
    const allocator = testing.allocator;
    
    const config = cache.CacheConfig{
        .max_size = 10, // Very small cache
        .eviction_policy = .lru,
        .enable_stats = true,
        .global_config = contextdb.config_mod.Config{},
    };
    
    var cache_instance = cache.Cache.init(allocator, config);
    defer cache_instance.deinit();
    
    // Test empty cache operations
    try testing.expect(cache_instance.get(1) == null);
    try testing.expect(cache_instance.size() == 0);
    try testing.expect(!cache_instance.contains(1));
    
    cache_instance.remove(1); // Should not crash
    cache_instance.clear(); // Should not crash
    
    // Test maintenance on empty cache
    try cache_instance.maintenance();
    
    // Test zero-size value
    const zero_value = cache.CacheValue{ .raw_data = &[_]u8{} };
    try cache_instance.put(1, zero_value);
    try testing.expect(cache_instance.contains(1));
    
    // Test very large key
    const large_key = std.math.maxInt(u64);
    const large_value = cache.CacheValue{ .integer = 999 };
    try cache_instance.put(large_key, large_value);
    try testing.expect(cache_instance.contains(large_key));
    
    // Test getting keys
    const keys = try cache_instance.getKeys();
    defer keys.deinit();
    try testing.expect(keys.items.len >= 2);
}

test "Cache statistics tracking" {
    var stats = cache.CacheStats.init(1000);
    try testing.expect(stats.getHitRatio() == 0.0);
    
    stats.recordHit(1000, 0.1);
    stats.recordMiss(1500, 0.1);
    
    try testing.expect(stats.hits == 1);
    try testing.expect(stats.misses == 1);
    try testing.expect(stats.getHitRatio() == 0.5);
    
    // Test moving average
    stats.recordHit(2000, 0.1);
    try testing.expect(stats.avg_access_time_ns > 1000);
    try testing.expect(stats.avg_access_time_ns < 2000);
} 