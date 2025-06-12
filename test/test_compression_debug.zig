const std = @import("std");
const memora = @import("memora");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🔍 Debug: Compression/Decompression Content Analysis\n", .{});
    std.debug.print("==================================================\n\n", .{});

    // Clean up any existing test data
    std.fs.cwd().deleteTree("test_compression_debug") catch {};
    // DON'T clean up at the end so we can examine files
    // defer std.fs.cwd().deleteTree("test_compression_debug") catch {};

    // Initialize Memora with compression enabled
    const config = memora.MemoraConfig{
        .data_path = "test_compression_debug",
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

    std.debug.print("📸 Creating snapshot...\n", .{});
    
    const vectors = try db.getAllVectors();
    defer vectors.deinit();
    
    const nodes = try db.getAllNodes();
    defer nodes.deinit();
    
    const edges = try db.getAllEdges();
    defer edges.deinit();
    
    const memory_contents = [_]memora.types.MemoryContent{};
    
    var snapshot_info = try db.snapshot_manager.createSnapshot(vectors.items, nodes.items, edges.items, &memory_contents);
    defer snapshot_info.deinit();
    
    std.debug.print("✅ Snapshot created\n", .{});
    std.debug.print("Original data: {} nodes, {} edges\n", .{ nodes.items.len, edges.items.len });
    
    // Test loading the snapshot back to see if decompression works
    std.debug.print("\n🔄 Testing snapshot loading...\n", .{});
    
    const loaded_nodes = try db.snapshot_manager.loadNodes(&snapshot_info);
    defer loaded_nodes.deinit();
    
    const loaded_edges = try db.snapshot_manager.loadEdges(&snapshot_info);
    defer loaded_edges.deinit();
    
    std.debug.print("✅ Loaded {} nodes, {} edges\n", .{ loaded_nodes.items.len, loaded_edges.items.len });
    
    if (loaded_nodes.items.len > 0) {
        std.debug.print("First node: id={}, label='{s}'\n", .{ loaded_nodes.items[0].id, loaded_nodes.items[0].getLabelAsString() });
    } else {
        std.debug.print("❌ No nodes loaded!\n", .{});
    }
    
    if (loaded_edges.items.len > 0) {
        std.debug.print("First edge: from={}, to={}, kind={}\n", .{ loaded_edges.items[0].from, loaded_edges.items[0].to, loaded_edges.items[0].kind });
    } else {
        std.debug.print("❌ No edges loaded!\n", .{});
    }
    
    std.debug.print("\n📁 Files created in test_compression_debug/:\n", .{});
    for (snapshot_info.node_files.items) |node_file| {
        std.debug.print("  • {s}\n", .{node_file});
    }
    for (snapshot_info.edge_files.items) |edge_file| {
        std.debug.print("  • {s}\n", .{edge_file});
    }
} 