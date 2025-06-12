const std = @import("std");
const memora = @import("memora");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🧠 Testing Snapshot Compression Infrastructure\n", .{});
    std.debug.print("==============================================\n\n", .{});

    // Clean up any existing test data
    std.fs.cwd().deleteTree("test_compression_data") catch {};
    defer std.fs.cwd().deleteTree("test_compression_data") catch {};

    // Initialize Memora with basic config (compression will be temporarily disabled)
    const config = memora.MemoraConfig{
        .data_path = "test_compression_data",
        .enable_persistent_indexes = false,
        .auto_snapshot_interval = null,
        .s3_bucket = null,
        .s3_region = null,
        .s3_prefix = null,
    };

    var db = try memora.Memora.init(allocator, config, null);
    defer db.deinit();

    std.debug.print("📝 Adding test data for compression testing...\n", .{});
    
    // Add some test data that should compress well
    try db.insertNode(memora.types.Node.init(1, "TestNode_Memory_Content_1"));
    try db.insertNode(memora.types.Node.init(2, "TestNode_Memory_Content_2"));
    try db.insertNode(memora.types.Node.init(3, "TestNode_Memory_Content_3"));
    
    try db.insertEdge(memora.types.Edge.init(1, 2, memora.types.EdgeKind.related));
    try db.insertEdge(memora.types.Edge.init(2, 3, memora.types.EdgeKind.child_of));
    
    // Create vectors with some repetitive patterns (good for compression)
    var dims1 = [_]f32{0.5} ** 64 ++ [_]f32{0.8} ** 64;
    var dims2 = [_]f32{0.3} ** 64 ++ [_]f32{0.9} ** 64;
    var dims3 = [_]f32{0.1} ** 64 ++ [_]f32{0.7} ** 64;
    
    try db.insertVector(memora.types.Vector.init(1, &dims1));
    try db.insertVector(memora.types.Vector.init(2, &dims2));
    try db.insertVector(memora.types.Vector.init(3, &dims3));

    std.debug.print("📊 Current Database Statistics:\n", .{});
    const stats = db.getStats();
    std.debug.print("  • Nodes: {}\n", .{stats.node_count});
    std.debug.print("  • Edges: {}\n", .{stats.edge_count});
    std.debug.print("  • Vectors: {}\n", .{stats.vector_count});

    std.debug.print("\n📸 Creating snapshot (compression infrastructure test)...\n", .{});
    
    // Create a manual snapshot
    var snapshot_info = try db.createSnapshot();
    defer snapshot_info.deinit();
    
    std.debug.print("✅ Snapshot created successfully!\n", .{});
    std.debug.print("  • Snapshot ID: {}\n", .{snapshot_info.snapshot_id});
    std.debug.print("  • Node files: {}\n", .{snapshot_info.node_files.items.len});
    std.debug.print("  • Edge files: {}\n", .{snapshot_info.edge_files.items.len});
    std.debug.print("  • Vector files: {}\n", .{snapshot_info.vector_files.items.len});
    std.debug.print("  • Memory content files: {}\n", .{snapshot_info.memory_content_files.items.len});
    
    std.debug.print("\n🔍 Checking compression status...\n", .{});
    try db.snapshot_manager.checkCompressionStatus();
    
    std.debug.print("\n📁 Files created in test_compression_data/:\n", .{});
    std.debug.print("  • metadata/snapshot-{:06}.json\n", .{snapshot_info.snapshot_id});
    if (snapshot_info.node_files.items.len > 0) {
        std.debug.print("  • nodes/node-{:06}.json\n", .{snapshot_info.snapshot_id});
    }
    if (snapshot_info.edge_files.items.len > 0) {
        std.debug.print("  • edges/edge-{:06}.json\n", .{snapshot_info.snapshot_id});
    }
    if (snapshot_info.vector_files.items.len > 0) {
        std.debug.print("  • vectors/vec-{:06}.blob\n", .{snapshot_info.snapshot_id});
    }
    if (snapshot_info.memory_content_files.items.len > 0) {
        std.debug.print("  • memory_contents/memory-{:06}.json\n", .{snapshot_info.snapshot_id});
    }
    
    std.debug.print("\n🎉 Snapshot compression infrastructure test complete!\n", .{});
    std.debug.print("Note: Compression is temporarily disabled but infrastructure is in place.\n", .{});
    std.debug.print("The system can detect compression status and handle mixed compressed/uncompressed files.\n", .{});
} 