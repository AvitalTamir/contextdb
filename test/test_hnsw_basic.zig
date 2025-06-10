const std = @import("std");
const testing = std.testing;
const memora = @import("memora");
const types = memora.types;

// Basic HNSW tests that pass without memory leaks
// These demonstrate core functionality and deterministic behavior

test "HNSW basic initialization" {
    const allocator = testing.allocator;
    
    var hnsw = try memora.vector.HNSWIndex.init(allocator, .{
        .max_connections = 16,
        .max_connections_layer0 = 32,
        .ef_construction = 200,
        .ml = 1.0 / @log(2.0),
        .seed = 42,
    });
    defer hnsw.deinit();

    // Test that it initializes correctly
    const stats = hnsw.getStats();
    try testing.expect(stats.num_vectors == 0);
    try testing.expect(stats.num_layers >= 1);
    try testing.expect(stats.entry_point == 0);
}

test "HNSW single vector insertion" {
    const allocator = testing.allocator;
    
    var hnsw = try memora.vector.HNSWIndex.init(allocator, .{
        .max_connections = 8,
        .max_connections_layer0 = 16,
        .ef_construction = 100,
        .ml = 1.0 / @log(2.0),
        .seed = 42,
    });
    defer hnsw.deinit();

    // Insert a single vector
    const dims = [_]f32{ 1.0, 0.0, 0.0 } ++ [_]f32{0.0} ** 125;
    const vector = types.Vector.init(1, &dims);
    try hnsw.insert(vector);
    
    // Test statistics
    const stats = hnsw.getStats();
    try testing.expect(stats.num_vectors == 1);
    try testing.expect(stats.entry_point == 1);
    
    // Test search functionality
    const results = try hnsw.search(1, 1, 50);
    defer results.deinit();
    try testing.expect(results.items.len == 0); // Should not return self
}

test "HNSW deterministic construction" {
    const allocator = testing.allocator;
    
    const config = memora.vector.HNSWConfig{
        .max_connections = 4,
        .max_connections_layer0 = 8,
        .ef_construction = 50,
        .ml = 1.0 / @log(2.0),
        .seed = 12345, // Fixed seed for determinism
    };
    
    // Create two identical indexes
    var hnsw1 = try memora.vector.HNSWIndex.init(allocator, config);
    defer hnsw1.deinit();
    
    var hnsw2 = try memora.vector.HNSWIndex.init(allocator, config);
    defer hnsw2.deinit();

    // Insert same vector in both
    const dims = [_]f32{ 0.5, 0.5, 0.0 } ++ [_]f32{0.0} ** 125;
    const vector = types.Vector.init(1, &dims);
    
    try hnsw1.insert(vector);
    try hnsw2.insert(vector);

    // Both should have identical stats
    const stats1 = hnsw1.getStats();
    const stats2 = hnsw2.getStats();
    
    try testing.expect(stats1.num_vectors == stats2.num_vectors);
    try testing.expect(stats1.num_layers == stats2.num_layers);
    try testing.expect(stats1.entry_point == stats2.entry_point);
}

test "HNSW empty search" {
    const allocator = testing.allocator;
    
    var hnsw = try memora.vector.HNSWIndex.init(allocator, .{
        .max_connections = 4,
        .max_connections_layer0 = 8,
        .ef_construction = 50,
        .ml = 1.0 / @log(2.0),
        .seed = 999,
    });
    defer hnsw.deinit();

    // Search in empty index
    const empty_result = try hnsw.search(1, 5, 50);
    defer empty_result.deinit();
    try testing.expect(empty_result.items.len == 0);
    
    // Search for non-existent vector
    const missing_result = try hnsw.search(999, 5, 50);
    defer missing_result.deinit();
    try testing.expect(missing_result.items.len == 0);
}

test "HNSW configuration validation" {
    const allocator = testing.allocator;
    
    // Test with minimal configuration
    var hnsw = try memora.vector.HNSWIndex.init(allocator, .{
        .max_connections = 1,
        .max_connections_layer0 = 2,
        .ef_construction = 10,
        .ml = 0.5,
        .seed = 1,
    });
    defer hnsw.deinit();
    
    // Should initialize successfully
    const stats = hnsw.getStats();
    try testing.expect(stats.num_vectors == 0);
    try testing.expect(stats.num_layers >= 1);
} 