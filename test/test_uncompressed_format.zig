const std = @import("std");
const memora = @import("memora");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🔍 Testing Uncompressed JSON Format\n", .{});
    std.debug.print("===================================\n\n", .{});

    // Clean up any existing test data
    std.fs.cwd().deleteTree("test_uncompressed_format") catch {};

    // Initialize Memora with compression DISABLED to see the raw JSON format
    const config = memora.MemoraConfig{
        .data_path = "test_uncompressed_format",
        .enable_persistent_indexes = false,
        .auto_snapshot_interval = null,
        .s3_bucket = null,
        .s3_region = null,
        .s3_prefix = null,
    };

    var db = try memora.Memora.init(allocator, config, null);
    defer db.deinit();

    // Add a simple test node
    const test_node = memora.types.Node.init(1, "TestNode");
    try db.insertNode(test_node);
    
    // Add a simple test edge
    const test_edge = memora.types.Edge.init(1, 2, memora.types.EdgeKind.related);
    try db.insertEdge(test_edge);

    std.debug.print("📸 Creating uncompressed snapshot...\n", .{});
    
    const vectors = try db.getAllVectors();
    defer vectors.deinit();
    
    const nodes = try db.getAllNodes();
    defer nodes.deinit();
    
    const edges = try db.getAllEdges();
    defer edges.deinit();
    
    const memory_contents = [_]memora.types.MemoryContent{};
    
    // Temporarily disable compression in the snapshot manager
    const original_compression = db.snapshot_manager.config.compression_enable;
    db.snapshot_manager.config.compression_enable = false;
    
    var snapshot_info = try db.snapshot_manager.createSnapshot(vectors.items, nodes.items, edges.items, &memory_contents);
    defer snapshot_info.deinit();
    
    // Restore original compression setting
    db.snapshot_manager.config.compression_enable = original_compression;
    
    std.debug.print("✅ Uncompressed snapshot created\n", .{});
    
    // Now read and display the JSON files
    for (snapshot_info.node_files.items) |node_file| {
        const file_path = try std.fs.path.join(allocator, &[_][]const u8{ "test_uncompressed_format", node_file });
        defer allocator.free(file_path);
        
        std.debug.print("\n📄 Node file content ({s}):\n", .{node_file});
        
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        
        const content = try file.readToEndAlloc(allocator, 1024);
        defer allocator.free(content);
        
        std.debug.print("'{s}'\n", .{content});
    }
    
    for (snapshot_info.edge_files.items) |edge_file| {
        const file_path = try std.fs.path.join(allocator, &[_][]const u8{ "test_uncompressed_format", edge_file });
        defer allocator.free(file_path);
        
        std.debug.print("\n📄 Edge file content ({s}):\n", .{edge_file});
        
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        
        const content = try file.readToEndAlloc(allocator, 1024);
        defer allocator.free(content);
        
        std.debug.print("'{s}'\n", .{content});
    }
    
    // Test loading the uncompressed files
    std.debug.print("\n🔄 Testing uncompressed loading...\n", .{});
    
    const loaded_nodes = try db.snapshot_manager.loadNodes(&snapshot_info);
    defer loaded_nodes.deinit();
    
    const loaded_edges = try db.snapshot_manager.loadEdges(&snapshot_info);
    defer loaded_edges.deinit();
    
    std.debug.print("✅ Loaded {} nodes, {} edges from uncompressed files\n", .{ loaded_nodes.items.len, loaded_edges.items.len });
} 