const std = @import("std");
const testing = std.testing;
const compression = @import("../src/compression.zig");
const types = @import("../src/types.zig");

test "CompressionEngine initialization and cleanup" {
    const allocator = testing.allocator;
    
    const config = compression.CompressionConfig{
        .vector_quantization_scale = 255.0,
        .compression_level = 3,
        .compression_min_ratio_threshold = 1.5,
    };
    
    var engine = compression.CompressionEngine.init(allocator, config);
    defer engine.deinit();
    
    const stats = engine.getStats();
    try testing.expect(stats.vectors_compressed == 0);
    try testing.expect(stats.total_bytes_saved == 0);
}

test "Vector compression and decompression" {
    const allocator = testing.allocator;
    
    const config = compression.CompressionConfig{};
    var engine = compression.CompressionEngine.init(allocator, config);
    defer engine.deinit();
    
    // Create test vectors with realistic embedding-like data
    var test_vectors = std.ArrayList(types.Vector).init(allocator);
    defer test_vectors.deinit();
    
    // Generate vectors with some patterns that should compress well
    for (0..1000) |i| {
        var dims: [128]f32 = undefined;
        const base_val = @as(f32, @floatFromInt(i % 10)) / 10.0; // Some repetition
        
        for (0..128) |j| {
            const noise = @as(f32, @floatFromInt((i * 7 + j) % 100)) / 1000.0;
            dims[j] = base_val + noise;
        }
        
        const vector = types.Vector{
            .id = i,
            .dims = dims,
        };
        try test_vectors.append(vector);
    }
    
    // Compress vectors
    var compressed = try engine.compressVectors(test_vectors.items);
    defer compressed.deinit(allocator);
    
    try testing.expect(compressed.original_count == 1000);
    try testing.expect(compressed.compression_method == .vector_quantized);
    try testing.expect(compressed.compression_ratio > 1.0);
    
    std.debug.print("Vector compression ratio: {d:.2f}x\n", .{compressed.compression_ratio});
    
    // Decompress vectors
    var decompressed = try engine.decompressVectors(&compressed);
    defer decompressed.deinit();
    
    try testing.expect(decompressed.items.len == test_vectors.items.len);
    
    // Verify vector IDs are preserved
    for (test_vectors.items, decompressed.items) |original, decompressed_vec| {
        try testing.expect(original.id == decompressed_vec.id);
        
        // Check that dimensions are reasonably close (quantization introduces some error)
        for (original.dims, decompressed_vec.dims) |orig_dim, decomp_dim| {
            const error_margin = @abs(orig_dim - decomp_dim);
            try testing.expect(error_margin < 0.1); // Should be quite close with 8-bit quantization
        }
    }
    
    const stats = engine.getStats();
    try testing.expect(stats.vectors_compressed == 1000);
    try testing.expect(stats.total_bytes_saved > 0);
    
    std.debug.print("Compression saved {} bytes\n", .{stats.total_bytes_saved});
    std.debug.print("Compression throughput: {d:.2f} MB/s\n", .{stats.getCompressionThroughput()});
}

test "Binary data compression with RLE" {
    const allocator = testing.allocator;
    
    const config = compression.CompressionConfig{
        .rle_min_run_length = 3,
    };
    var engine = compression.CompressionEngine.init(allocator, config);
    defer engine.deinit();
    
    // Create test data with repetitive patterns (good for RLE)
    var test_data = std.ArrayList(u8).init(allocator);
    defer test_data.deinit();
    
    // Pattern: blocks of repeated bytes
    for (0..100) |i| {
        const byte_val = @as(u8, @intCast(i % 10));
        for (0..50) |_| {
            try test_data.append(byte_val);
        }
    }
    
    const original_size = test_data.items.len;
    
    // Compress data
    var compressed = try engine.compressBinary(test_data.items);
    defer compressed.deinit(allocator);
    
    try testing.expect(compressed.original_size == original_size);
    try testing.expect(compressed.compression_method == .lz4_fast);
    try testing.expect(compressed.compression_ratio > 1.0);
    
    std.debug.print("Binary compression ratio: {d:.2f}x\n", .{compressed.compression_ratio});
    
    // Decompress data
    const decompressed = try engine.decompressBinary(&compressed);
    defer allocator.free(decompressed);
    
    try testing.expect(decompressed.len == test_data.items.len);
    try testing.expectEqualSlices(u8, test_data.items, decompressed);
    
    const stats = engine.getStats();
    try testing.expect(stats.binary_blocks_compressed == 1);
}

test "Compression with small datasets (should skip compression)" {
    const allocator = testing.allocator;
    
    var engine = compression.CompressionEngine.init(allocator, .{});
    defer engine.deinit();
    
    // Small vector dataset (below threshold)
    var small_vectors = [_]types.Vector{
        types.Vector.init(1, &[_]f32{1.0} ++ [_]f32{0.0} ** 127),
        types.Vector.init(2, &[_]f32{2.0} ++ [_]f32{0.0} ** 127),
    };
    
    var compressed = try engine.compressVectors(&small_vectors);
    defer compressed.deinit(allocator);
    
    // Should still work but may not achieve high compression
    try testing.expect(compressed.original_count == 2);
    
    var decompressed = try engine.decompressVectors(&compressed);
    defer decompressed.deinit();
    
    try testing.expect(decompressed.items.len == 2);
    try testing.expect(decompressed.items[0].id == 1);
    try testing.expect(decompressed.items[1].id == 2);
}

test "Compression error handling" {
    const allocator = testing.allocator;
    
    var engine = compression.CompressionEngine.init(allocator, .{});
    defer engine.deinit();
    
    // Test with empty datasets
    var empty_compressed = try engine.compressVectors(&[_]types.Vector{});
    defer empty_compressed.deinit(allocator);
    
    try testing.expect(empty_compressed.original_count == 0);
    
    var empty_decompressed = try engine.decompressVectors(&empty_compressed);
    defer empty_decompressed.deinit();
    
    try testing.expect(empty_decompressed.items.len == 0);
    
    // Test binary compression with empty data
    var empty_binary = try engine.compressBinary(&[_]u8{});
    defer empty_binary.deinit(allocator);
    
    try testing.expect(empty_binary.original_size == 0);
    
    const empty_binary_decompressed = try engine.decompressBinary(&empty_binary);
    defer allocator.free(empty_binary_decompressed);
    
    try testing.expect(empty_binary_decompressed.len == 0);
}

test "CompressionUtils estimation functions" {
    // Test vector compression ratio estimation
    var test_vectors = [_]types.Vector{
        types.Vector.init(1, &[_]f32{1.0} ++ [_]f32{0.0} ** 127),
        types.Vector.init(2, &[_]f32{0.5} ++ [_]f32{0.0} ** 127),
    };
    
    const estimated_ratio = compression.CompressionUtils.estimateVectorCompressionRatio(&test_vectors);
    try testing.expect(estimated_ratio > 1.0);
    
    // Test binary compression estimation
    const test_data = [_]u8{0, 0, 0, 1, 1, 1, 2, 2, 2}; // Some repetition
    const binary_ratio = compression.CompressionUtils.estimateBinaryCompressionRatio(&test_data);
    try testing.expect(binary_ratio > 1.0);
    
    // Test compression decision
    try testing.expect(compression.CompressionUtils.shouldCompress(&test_data, 5, 1.5));
    try testing.expect(!compression.CompressionUtils.shouldCompress(&test_data, 20, 1.5)); // Too small
}

test "Compression statistics tracking" {
    const allocator = testing.allocator;
    
    var engine = compression.CompressionEngine.init(allocator, .{});
    defer engine.deinit();
    
    // Initial stats should be zero
    var stats = engine.getStats();
    try testing.expect(stats.vectors_compressed == 0);
    try testing.expect(stats.binary_blocks_compressed == 0);
    try testing.expect(stats.total_bytes_saved == 0);
    
    // Compress some data
    var test_vectors = [_]types.Vector{
        types.Vector.init(1, &[_]f32{1.0} ++ [_]f32{0.0} ** 127),
    };
    
    var compressed = try engine.compressVectors(&test_vectors);
    defer compressed.deinit(allocator);
    
    // Stats should update
    stats = engine.getStats();
    try testing.expect(stats.vectors_compressed == 1);
    
    // Reset stats
    engine.resetStats();
    stats = engine.getStats();
    try testing.expect(stats.vectors_compressed == 0);
    try testing.expect(stats.total_bytes_saved == 0);
}

test "Vector compression with extreme values" {
    const allocator = testing.allocator;
    
    var engine = compression.CompressionEngine.init(allocator, .{});
    defer engine.deinit();
    
    // Create vectors with extreme values to test quantization
    var extreme_vectors = [_]types.Vector{
        types.Vector.init(1, &([_]f32{-100.0} ++ [_]f32{0.0} ** 127)),
        types.Vector.init(2, &([_]f32{100.0} ++ [_]f32{0.0} ** 127)),
        types.Vector.init(3, &([_]f32{0.001} ++ [_]f32{0.0} ** 127)),
    };
    
    var compressed = try engine.compressVectors(&extreme_vectors);
    defer compressed.deinit(allocator);
    
    var decompressed = try engine.decompressVectors(&compressed);
    defer decompressed.deinit();
    
    try testing.expect(decompressed.items.len == 3);
    
    // Values should be preserved reasonably well despite quantization
    for (extreme_vectors, decompressed.items) |original, decompressed_vec| {
        try testing.expect(original.id == decompressed_vec.id);
        // First dimension contains the extreme value
        const error_ratio = @abs(original.dims[0] - decompressed_vec.dims[0]) / @abs(original.dims[0]);
        try testing.expect(error_ratio < 0.01); // Should be within 1% for extreme values
    }
}

test "Binary compression with no repetition (worst case)" {
    const allocator = testing.allocator;
    
    var engine = compression.CompressionEngine.init(allocator, .{});
    defer engine.deinit();
    
    // Create data with no repetition (worst case for RLE)
    var random_data: [1000]u8 = undefined;
    for (0..1000) |i| {
        random_data[i] = @intCast((i * 7 + 13) % 256);
    }
    
    var compressed = try engine.compressBinary(&random_data);
    defer compressed.deinit(allocator);
    
    // Even with no repetition, should still work (just not compress well)
    try testing.expect(compressed.original_size == 1000);
    
    const decompressed = try engine.decompressBinary(&compressed);
    defer allocator.free(decompressed);
    
    try testing.expectEqualSlices(u8, &random_data, decompressed);
}

test "Performance benchmark" {
    const allocator = testing.allocator;
    
    var engine = compression.CompressionEngine.init(allocator, .{});
    defer engine.deinit();
    
    // Create a larger dataset for performance testing
    var large_vectors = std.ArrayList(types.Vector).init(allocator);
    defer large_vectors.deinit();
    
    const vector_count = 10000;
    for (0..vector_count) |i| {
        var dims: [128]f32 = undefined;
        for (0..128) |j| {
            dims[j] = @as(f32, @floatFromInt((i + j) % 100)) / 100.0;
        }
        
        try large_vectors.append(types.Vector{
            .id = i,
            .dims = dims,
        });
    }
    
    const start_time = std.time.nanoTimestamp();
    
    var compressed = try engine.compressVectors(large_vectors.items);
    defer compressed.deinit(allocator);
    
    const compress_time = std.time.nanoTimestamp() - start_time;
    const decompress_start = std.time.nanoTimestamp();
    
    var decompressed = try engine.decompressVectors(&compressed);
    defer decompressed.deinit();
    
    const decompress_time = std.time.nanoTimestamp() - decompress_start;
    
    try testing.expect(decompressed.items.len == vector_count);
    
    const original_size = vector_count * @sizeOf(types.Vector);
    const compress_mbps = (@as(f64, @floatFromInt(original_size)) / 1024.0 / 1024.0) / (@as(f64, @floatFromInt(compress_time)) / 1_000_000_000.0);
    const decompress_mbps = (@as(f64, @floatFromInt(original_size)) / 1024.0 / 1024.0) / (@as(f64, @floatFromInt(decompress_time)) / 1_000_000_000.0);
    
    std.debug.print("Performance benchmark ({} vectors):\n", .{vector_count});
    std.debug.print("  Compression: {d:.1f} MB/s\n", .{compress_mbps});
    std.debug.print("  Decompression: {d:.1f} MB/s\n", .{decompress_mbps});
    std.debug.print("  Compression ratio: {d:.2f}x\n", .{compressed.compression_ratio});
    
    // Performance assertions (adjust based on expected performance)
    try testing.expect(compress_mbps > 10.0); // Should compress at least 10 MB/s
    try testing.expect(decompress_mbps > 50.0); // Should decompress at least 50 MB/s
    try testing.expect(compressed.compression_ratio > 2.0); // Should achieve at least 2x compression
} 