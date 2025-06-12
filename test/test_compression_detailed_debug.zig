const std = @import("std");
const memora = @import("memora");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🔍 Detailed Debug: Compression/Decompression Analysis\n", .{});
    std.debug.print("===================================================\n\n", .{});

    // Clean up any existing test data
    std.fs.cwd().deleteTree("test_detailed_debug") catch {};

    // Initialize Memora with compression enabled
    const config = memora.MemoraConfig{
        .data_path = "test_detailed_debug",
        .enable_persistent_indexes = false,
        .auto_snapshot_interval = null,
        .s3_bucket = null,
        .s3_region = null,
        .s3_prefix = null,
    };

    var db = try memora.Memora.init(allocator, config, null);
    defer db.deinit();

    // Add test data
    const test_node = memora.types.Node.init(1, "TestNode");
    try db.insertNode(test_node);
    
    const test_edge = memora.types.Edge.init(1, 2, memora.types.EdgeKind.related);
    try db.insertEdge(test_edge);

    std.debug.print("📸 Creating compressed snapshot...\n", .{});
    
    const vectors = try db.getAllVectors();
    defer vectors.deinit();
    
    const nodes = try db.getAllNodes();
    defer nodes.deinit();
    
    const edges = try db.getAllEdges();
    defer edges.deinit();
    
    const memory_contents = [_]memora.types.MemoryContent{};
    
    var snapshot_info = try db.snapshot_manager.createSnapshot(vectors.items, nodes.items, edges.items, &memory_contents);
    defer snapshot_info.deinit();
    
    std.debug.print("✅ Snapshot created with {} nodes, {} edges\n", .{ nodes.items.len, edges.items.len });
    
    // Now let's manually test the readNodeFile function step by step
    for (snapshot_info.node_files.items) |node_file| {
        const file_path = try std.fs.path.join(allocator, &[_][]const u8{ "test_detailed_debug", node_file });
        defer allocator.free(file_path);
        
        std.debug.print("\n🔍 Debugging node file: {s}\n", .{node_file});
        
        // Step 1: Read raw file content
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        
        const raw_content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(raw_content);
        
        std.debug.print("Step 1 - Raw content length: {} bytes\n", .{raw_content.len});
        
        // Step 2: Check if it looks like JSON
        const looks_like_json = db.snapshot_manager.isLikelyJsonContent(raw_content);
        std.debug.print("Step 2 - Looks like JSON: {}\n", .{looks_like_json});
        
        if (!looks_like_json) {
            std.debug.print("Step 3 - Attempting decompression...\n", .{});
            
            // Step 3: Try decompression manually
            const compression = @import("../src/compression.zig");
            const comp_config = compression.CompressionConfig{
                .enable_checksums = true,
                .compression_level = 6,
                .rle_min_run_length = 3,
            };
            var comp_engine = compression.CompressionEngine.init(allocator, comp_config);
            defer comp_engine.deinit();
            
            // We need to read the header to get the original size
            if (raw_content.len < @sizeOf(compression.BinaryCompressionHeader)) {
                std.debug.print("Step 3 - File too small to contain header\n", .{});
                continue;
            }
            
            const header_bytes = raw_content[0..@sizeOf(compression.BinaryCompressionHeader)];
            const header = std.mem.bytesToValue(compression.BinaryCompressionHeader, header_bytes);
            
            std.debug.print("Step 3 - Header magic: 0x{X}, original_size: {}\n", .{ header.magic, header.original_size });
            
            const compressed_binary = compression.CompressedBinaryData{
                .compressed_data = @constCast(raw_content),
                .original_size = header.original_size,
                .compression_method = header.method,
                .compression_ratio = 1.0,
            };
            
            if (comp_engine.decompressBinary(&compressed_binary)) |decompressed_bytes| {
                defer allocator.free(decompressed_bytes);
                std.debug.print("Step 3 - Decompression successful: {} bytes\n", .{decompressed_bytes.len});
                std.debug.print("Step 3 - Decompressed content: '{s}'\n", .{decompressed_bytes});
                
                // Step 4: Test JSON parsing on decompressed content
                std.debug.print("Step 4 - Testing JSON parsing...\n", .{});
                const parsed_nodes = db.snapshot_manager.parseNodesJson(decompressed_bytes) catch |err| {
                    std.debug.print("Step 4 - JSON parsing failed: {}\n", .{err});
                    continue;
                };
                defer parsed_nodes.deinit();
                
                std.debug.print("Step 4 - Parsed {} nodes successfully\n", .{parsed_nodes.items.len});
                for (parsed_nodes.items) |node| {
                    std.debug.print("  Node: id={}, label='{s}'\n", .{ node.id, node.getLabelAsString() });
                }
            } else |err| {
                std.debug.print("Step 3 - Decompression failed: {}\n", .{err});
            }
        } else {
            std.debug.print("Step 3 - Content is already JSON, testing parsing...\n", .{});
            const parsed_nodes = db.snapshot_manager.parseNodesJson(raw_content) catch |err| {
                std.debug.print("Step 3 - JSON parsing failed: {}\n", .{err});
                continue;
            };
            defer parsed_nodes.deinit();
            
            std.debug.print("Step 3 - Parsed {} nodes successfully\n", .{parsed_nodes.items.len});
        }
    }
    
    // Test the actual loadNodes function
    std.debug.print("\n🔄 Testing actual loadNodes function...\n", .{});
    const loaded_nodes = try db.snapshot_manager.loadNodes(&snapshot_info);
    defer loaded_nodes.deinit();
    
    std.debug.print("✅ loadNodes returned {} nodes\n", .{loaded_nodes.items.len});
} 