const std = @import("std");
const testing = std.testing;
const memora = @import("memora");
const types = memora.types;

// HNSW (Hierarchical Navigable Small World) Index Tests
// Following TigerBeetle-style programming: comprehensive, deterministic, zero external dependencies

test "HNSW basic construction and search" {
    const allocator = testing.allocator;
    
    var hnsw = try memora.vector.HNSWIndex.init(allocator, .{
        .max_connections = 16,
        .max_connections_layer0 = 32,
        .ef_construction = 200,
        .ml = 1.0 / @log(2.0),
        .seed = 42, // Deterministic for testing
    });
    defer hnsw.deinit();

    // Test vector insertion with deterministic data
    const test_vectors = [_][4]f32{
        [_]f32{ 1.0, 0.0, 0.0, 0.0 },  // Vector 1
        [_]f32{ 0.9, 0.1, 0.0, 0.0 },  // Vector 2 - very similar to 1
        [_]f32{ 0.0, 1.0, 0.0, 0.0 },  // Vector 3 - orthogonal to 1
        [_]f32{ 0.0, 0.0, 1.0, 0.0 },  // Vector 4 - orthogonal to 1 and 3
        [_]f32{ 0.7, 0.7, 0.0, 0.0 },  // Vector 5 - moderately similar to 1
        [_]f32{ -1.0, 0.0, 0.0, 0.0 }, // Vector 6 - opposite to 1
        [_]f32{ 0.0, -1.0, 0.0, 0.0 }, // Vector 7 - opposite to 3
        [_]f32{ 0.0, 0.0, -1.0, 0.0 }, // Vector 8 - opposite to 4
    };

    // Insert vectors
    for (test_vectors, 1..) |base_dims, i| {
        const full_dims = base_dims ++ [_]f32{0.0} ** 124;
        const vector = types.Vector.init(@intCast(i), &full_dims);
        try hnsw.insert(vector);
    }

    // Test basic search functionality
    const similar = try hnsw.search(1, 3, 50); // id=1, k=3, ef=50
    defer similar.deinit();

    // Verify search results
    try testing.expect(similar.items.len <= 3);
    try testing.expect(similar.items.len >= 1);
    
    // First result should be vector 2 (most similar to vector 1)
    try testing.expect(similar.items[0].id == 2);
    try testing.expect(similar.items[0].similarity > 0.9);
    
    // Test statistics
    const stats = hnsw.getStats();
    try testing.expect(stats.num_vectors == 8);
    try testing.expect(stats.num_layers >= 1);
    try testing.expect(stats.entry_point != 0);
}

test "HNSW deterministic behavior" {
    const allocator = testing.allocator;
    
    // Test that HNSW produces consistent results with same seed
    const config = memora.vector.HNSWConfig{
        .max_connections = 8,
        .max_connections_layer0 = 16,
        .ef_construction = 100,
        .ml = 1.0 / @log(2.0),
        .seed = 12345, // Fixed seed for determinism
    };
    
    var hnsw1 = try memora.vector.HNSWIndex.init(allocator, config);
    defer hnsw1.deinit();
    
    var hnsw2 = try memora.vector.HNSWIndex.init(allocator, config);
    defer hnsw2.deinit();

    // Insert same data in both indexes
    const test_data = [_][3]f32{
        [_]f32{ 1.0, 2.0, 3.0 },
        [_]f32{ 4.0, 5.0, 6.0 },
        [_]f32{ 7.0, 8.0, 9.0 },
        [_]f32{ 2.0, 4.0, 6.0 },
        [_]f32{ 3.0, 6.0, 9.0 },
    };

    for (test_data, 1..) |base_dims, i| {
        const full_dims = base_dims ++ [_]f32{0.0} ** 125;
        const vector = types.Vector.init(@intCast(i), &full_dims);
        try hnsw1.insert(vector);
        try hnsw2.insert(vector);
    }

    // Search both indexes
    const result1 = try hnsw1.search(1, 3, 50);
    defer result1.deinit();
    
    const result2 = try hnsw2.search(1, 3, 50);
    defer result2.deinit();

    // Results should be identical
    try testing.expect(result1.items.len == result2.items.len);
    for (result1.items, result2.items) |r1, r2| {
        try testing.expect(r1.id == r2.id);
        try testing.expect(@abs(r1.similarity - r2.similarity) < 0.001);
    }

    // Graph structure should be identical
    const stats1 = hnsw1.getStats();
    const stats2 = hnsw2.getStats();
    try testing.expect(stats1.num_vectors == stats2.num_vectors);
    try testing.expect(stats1.num_layers == stats2.num_layers);
    try testing.expect(stats1.entry_point == stats2.entry_point);
}

test "HNSW stress test with many vectors" {
    const allocator = testing.allocator;
    
    var hnsw = try memora.vector.HNSWIndex.init(allocator, .{
        .max_connections = 16,
        .max_connections_layer0 = 32,
        .ef_construction = 200,
        .ml = 1.0 / @log(2.0),
        .seed = 2024,
    });
    defer hnsw.deinit();

    const num_vectors = 1000; // Stress test with 1000 vectors
    var timer = try std.time.Timer.start();
    
    // Generate and insert vectors
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    
    for (0..num_vectors) |i| {
        var dims = [_]f32{0.0} ** 128;
        
        // Generate random normalized vector
        var norm: f32 = 0.0;
        for (&dims) |*dim| {
            dim.* = random.floatNorm(f32);
            norm += dim.* * dim.*;
        }
        norm = @sqrt(norm);
        
        // Normalize
        for (&dims) |*dim| {
            dim.* /= norm;
        }
        
        const vector = types.Vector.init(@intCast(i + 1), &dims);
        try hnsw.insert(vector);
    }
    
    const insert_time = timer.lap();
    
    // Test search performance
    const num_searches = 100;
    var total_results: u64 = 0;
    
    for (0..num_searches) |i| {
        const query_id = @as(u64, @intCast((i * 13) % num_vectors + 1)); // Deterministic query selection
        const results = try hnsw.search(query_id, 10, 100);
        defer results.deinit();
        
        total_results += results.items.len;
        
        // Verify result quality
        for (results.items) |result| {
            try testing.expect(result.similarity >= -1.01 and result.similarity <= 1.01);
            if (result.id == query_id) {
                try testing.expect(result.similarity > 0.99); // Self-similarity should be near 1.0
            }
        }
    }
    
    const search_time = timer.lap();
    
    // Performance assertions
    try testing.expect(insert_time < 5_000_000_000); // < 5 seconds for 1000 inserts
    try testing.expect(search_time < 1_000_000_000);  // < 1 second for 100 searches
    try testing.expect(total_results > 0);
    
    // Verify index integrity
    const stats = hnsw.getStats();
    try testing.expect(stats.num_vectors == num_vectors);
    try testing.expect(stats.num_layers >= 1);
    try testing.expect(stats.num_layers <= 10); // Reasonable layer count
    
    std.debug.print("\nHNSW Stress Test Results ({} vectors):\n", .{num_vectors});
    std.debug.print("  Insert time: {}ns ({} per vector)\n", .{ insert_time, insert_time / num_vectors });
    std.debug.print("  Search time: {}ns ({} per search)\n", .{ search_time, search_time / num_searches });
    std.debug.print("  Layers: {}, Entry point: {}\n", .{ stats.num_layers, stats.entry_point });
    std.debug.print("  Avg results per search: {d:.1}\n", .{ @as(f64, @floatFromInt(total_results)) / @as(f64, @floatFromInt(num_searches)) });
}

test "HNSW edge cases and error handling" {
    const allocator = testing.allocator;
    
    var hnsw = try memora.vector.HNSWIndex.init(allocator, .{
        .max_connections = 4,
        .max_connections_layer0 = 8,
        .ef_construction = 50,
        .ml = 1.0 / @log(2.0),
        .seed = 999,
    });
    defer hnsw.deinit();

    // Test empty index search
    const empty_result = try hnsw.search(1, 5, 50);
    defer empty_result.deinit();
    try testing.expect(empty_result.items.len == 0);

    // Test single vector
    const single_dims = [_]f32{ 0.5, 0.5, 0.5 } ++ [_]f32{0.0} ** 125;
    try hnsw.insert(types.Vector.init(1, &single_dims));
    
    const single_result = try hnsw.search(1, 5, 50);
    defer single_result.deinit();
    try testing.expect(single_result.items.len == 1);
    try testing.expect(single_result.items[0].id == 1);
    try testing.expect(single_result.items[0].similarity > 0.99);

    // Test search for non-existent vector
    const missing_result = try hnsw.search(999, 5, 50);
    defer missing_result.deinit();
    try testing.expect(missing_result.items.len == 0);

    // Test zero vector (edge case)
    const zero_dims = [_]f32{0.0} ** 128;
    try hnsw.insert(types.Vector.init(2, &zero_dims));
    
    const zero_result = try hnsw.search(2, 2, 50);
    defer zero_result.deinit();
    try testing.expect(zero_result.items.len <= 2);

    // Test identical vectors
    try hnsw.insert(types.Vector.init(3, &single_dims)); // Same as vector 1
    
    const identical_result = try hnsw.search(1, 3, 50);
    defer identical_result.deinit();
    try testing.expect(identical_result.items.len >= 2); // Should find both identical vectors
    
    // Check that identical vectors have high similarity
    var found_identical = false;
    for (identical_result.items) |result| {
        if (result.id == 3) {
            try testing.expect(result.similarity > 0.99);
            found_identical = true;
        }
    }
    try testing.expect(found_identical);
}

test "HNSW layer distribution and connectivity" {
    const allocator = testing.allocator;
    
    var hnsw = try memora.vector.HNSWIndex.init(allocator, .{
        .max_connections = 8,
        .max_connections_layer0 = 16,
        .ef_construction = 100,
        .ml = 1.0 / @log(2.0),
        .seed = 7777,
    });
    defer hnsw.deinit();

    // Insert enough vectors to generate multiple layers
    const num_vectors = 200;
    var prng = std.Random.DefaultPrng.init(7777);
    const random = prng.random();

    for (0..num_vectors) |i| {
        var dims = [_]f32{0.0} ** 128;
        
        // Generate clustered data (creates interesting connectivity patterns)
        const cluster = i % 4;
        const base_value = @as(f32, @floatFromInt(cluster)) * 0.3;
        
        for (&dims, 0..) |*dim, j| {
            if (j < 32) { // First 32 dimensions are cluster-specific
                dim.* = base_value + random.floatNorm(f32) * 0.1;
            } else {
                dim.* = random.floatNorm(f32) * 0.05; // Noise
            }
        }
        
        const vector = types.Vector.init(@intCast(i + 1), &dims);
        try hnsw.insert(vector);
    }

    const stats = hnsw.getStats();
    try testing.expect(stats.num_vectors == num_vectors);
    try testing.expect(stats.num_layers >= 2); // Should have multiple layers
    
    // Test connectivity: search from different clusters
    for (0..4) |cluster| {
        const query_id = @as(u64, @intCast(cluster * 50 + 1)); // One from each cluster
        const results = try hnsw.search(query_id, 20, 100);
        defer results.deinit();
        
        try testing.expect(results.items.len >= 10); // Should find reasonable number of neighbors
        
        // Verify that results are properly ordered by similarity
        for (0..results.items.len - 1) |i| {
            try testing.expect(results.items[i].similarity >= results.items[i + 1].similarity);
        }
    }
    
    std.debug.print("\nHNSW Connectivity Test ({} vectors):\n", .{num_vectors});
    std.debug.print("  Layers: {}, Entry point: {}\n", .{ stats.num_layers, stats.entry_point });
}

test "HNSW memory safety and cleanup" {
    const allocator = testing.allocator;
    
    // Test multiple create/destroy cycles
    for (0..5) |cycle| {
        var hnsw = try memora.vector.HNSWIndex.init(allocator, .{
            .max_connections = 8,
            .max_connections_layer0 = 16,
            .ef_construction = 50,
            .ml = 1.0 / @log(2.0),
            .seed = @intCast(cycle + 1),
        });
        
        // Add some data
        for (0..10) |i| {
            var dims = [_]f32{0.0} ** 128;
            dims[0] = @floatFromInt(i);
            dims[1] = @floatFromInt(cycle);
            
            const vector = types.Vector.init(@intCast(i + 1), &dims);
            try hnsw.insert(vector);
        }
        
        // Do some searches
        const results = try hnsw.search(1, 5, 25);
        defer results.deinit();
        try testing.expect(results.items.len <= 5);
        
        hnsw.deinit(); // Explicit cleanup
    }
}

test "HNSW configuration validation" {
    const allocator = testing.allocator;
    
    // Test valid configurations
    const valid_configs = [_]memora.vector.HNSWConfig{
        .{ .max_connections = 1, .max_connections_layer0 = 2, .ef_construction = 10, .ml = 0.5, .seed = 1 },
        .{ .max_connections = 64, .max_connections_layer0 = 128, .ef_construction = 500, .ml = 2.0, .seed = 2 },
        .{ .max_connections = 16, .max_connections_layer0 = 32, .ef_construction = 200, .ml = 1.0 / @log(2.0), .seed = 3 },
    };
    
    for (valid_configs) |config| {
        var hnsw = try memora.vector.HNSWIndex.init(allocator, config);
        defer hnsw.deinit();
        
        // Basic functionality test
        const dims = [_]f32{ 1.0, 0.0, 0.0 } ++ [_]f32{0.0} ** 125;
        try hnsw.insert(types.Vector.init(1, &dims));
        
        const results = try hnsw.search(1, 1, 10);
        defer results.deinit();
        try testing.expect(results.items.len == 1);
    }
}

// Fuzzing-style test with random operations
test "HNSW fuzzing test" {
    const allocator = testing.allocator;
    
    var hnsw = try memora.vector.HNSWIndex.init(allocator, .{
        .max_connections = 12,
        .max_connections_layer0 = 24,
        .ef_construction = 100,
        .ml = 1.0 / @log(2.0),
        .seed = 31415,
    });
    defer hnsw.deinit();

    var prng = std.Random.DefaultPrng.init(31415);
    const random = prng.random();
    
    var inserted_ids = std.ArrayList(u64).init(allocator);
    defer inserted_ids.deinit();
    
    // Perform random operations
    for (0..500) |_| {
        const operation = random.intRangeAtMost(u8, 0, 2);
        
        switch (operation) {
            0 => { // Insert
                const id = random.intRangeAtMost(u64, 1, 10000);
                var dims = [_]f32{0.0} ** 128;
                
                for (&dims) |*dim| {
                    dim.* = random.floatNorm(f32);
                }
                
                const vector = types.Vector.init(id, &dims);
                try hnsw.insert(vector);
                try inserted_ids.append(id);
            },
            1 => { // Search existing
                if (inserted_ids.items.len > 0) {
                    const idx = random.intRangeAtMost(usize, 0, inserted_ids.items.len - 1);
                    const query_id = inserted_ids.items[idx];
                    const k = random.intRangeAtMost(u32, 1, 20);
                    const ef = random.intRangeAtMost(u32, k, 100);
                    
                    const results = try hnsw.search(query_id, k, ef);
                    defer results.deinit();
                    
                    // Verify result validity
                    try testing.expect(results.items.len <= k);
                    for (results.items) |result| {
                        try testing.expect(result.similarity >= -1.01 and result.similarity <= 1.01);
                    }
                }
            },
            2 => { // Search random (might not exist)
                const query_id = random.intRangeAtMost(u64, 1, 20000);
                const k = random.intRangeAtMost(u32, 1, 10);
                const ef = random.intRangeAtMost(u32, k, 50);
                
                const results = try hnsw.search(query_id, k, ef);
                defer results.deinit();
                
                // Results should be valid even if query doesn't exist
                for (results.items) |result| {
                    try testing.expect(result.similarity >= -1.01 and result.similarity <= 1.01);
                }
            },
            else => {
                // Should not happen with our random range, but needed for completeness
                unreachable;
            },
        }
    }
    
    // Final integrity check
    const stats = hnsw.getStats();
    try testing.expect(stats.num_vectors == inserted_ids.items.len);
    
    std.debug.print("\nHNSW Fuzzing Test Results:\n", .{});
    std.debug.print("  Vectors inserted: {}\n", .{inserted_ids.items.len});
    std.debug.print("  Layers: {}, Entry point: {}\n", .{ stats.num_layers, stats.entry_point });
} 