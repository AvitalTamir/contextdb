const std = @import("std");
const memora = @import("memora");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🧠 Testing Exit Snapshot Creation\n", .{});
    std.debug.print("=================================\n\n", .{});

    // Clean up any existing test data
    std.fs.cwd().deleteTree("test_exit_data") catch {};
    defer std.fs.cwd().deleteTree("test_exit_data") catch {};

    std.debug.print("📝 Phase 1: Creating database with data but no snapshots...\n", .{});
    
    // Initialize Memora
    const config = memora.MemoraConfig{
        .data_path = "test_exit_data",
        .enable_persistent_indexes = false,
        .auto_snapshot_interval = null, // Disable auto-snapshots to test manual exit snapshot
        .s3_bucket = null,
        .s3_region = null,
        .s3_prefix = null,
    };

    {
        var db = try memora.Memora.init(allocator, config, null);
        defer db.deinit(); // This should trigger createFinalSnapshot()

        std.debug.print("📊 Adding test data to log...\n", .{});
        
        // Add some test data that will only exist in the log
        try db.insertNode(memora.types.Node.init(1, "ExitTest_Node_1"));
        try db.insertNode(memora.types.Node.init(2, "ExitTest_Node_2"));
        try db.insertNode(memora.types.Node.init(3, "ExitTest_Node_3"));
        
        try db.insertEdge(memora.types.Edge.init(1, 2, memora.types.EdgeKind.related));
        try db.insertEdge(memora.types.Edge.init(2, 3, memora.types.EdgeKind.child_of));
        
        var dims1 = [_]f32{0.1} ** 128;
        var dims2 = [_]f32{0.2} ** 128;
        var dims3 = [_]f32{0.3} ** 128;
        
        try db.insertVector(memora.types.Vector.init(1, &dims1));
        try db.insertVector(memora.types.Vector.init(2, &dims2));
        try db.insertVector(memora.types.Vector.init(3, &dims3));

        const stats = db.getStats();
        std.debug.print("  • Nodes: {}\n", .{stats.node_count});
        std.debug.print("  • Edges: {}\n", .{stats.edge_count});
        std.debug.print("  • Vectors: {}\n", .{stats.vector_count});
        
        const log_entries = db.append_log.getEntryCount();
        std.debug.print("  • Log entries: {}\n", .{log_entries});
        
        std.debug.print("\n💾 Exiting database (should trigger final snapshot creation)...\n", .{});
        // db.deinit() will be called here due to defer, which should create final snapshot
    }
    
    std.debug.print("\n📝 Phase 2: Reloading database to verify data persistence...\n", .{});
    
    // Reinitialize the database to verify data was persisted via exit snapshot
    {
        var db2 = try memora.Memora.init(allocator, config, null);
        defer db2.deinit();
        
        const stats2 = db2.getStats();
        std.debug.print("📊 Reloaded Database Statistics:\n", .{});
        std.debug.print("  • Nodes: {}\n", .{stats2.node_count});
        std.debug.print("  • Edges: {}\n", .{stats2.edge_count});
        std.debug.print("  • Vectors: {}\n", .{stats2.vector_count});
        
        // Verify the data is actually there
        std.debug.print("\n🔍 Verifying data integrity...\n", .{});
        
        // Test node retrieval
        const nodes = try db2.getAllNodes();
        defer nodes.deinit();
        std.debug.print("  • Retrieved {} nodes from storage\n", .{nodes.items.len});
        
        // Test edge retrieval  
        const edges = try db2.getAllEdges();
        defer edges.deinit();
        std.debug.print("  • Retrieved {} edges from storage\n", .{edges.items.len});
        
        // Test vector retrieval
        const vectors = try db2.getAllVectors();
        defer vectors.deinit();
        std.debug.print("  • Retrieved {} vectors from storage\n", .{vectors.items.len});
        
        // Check if we have the expected data
        const expected_nodes = 3;
        const expected_edges = 2;
        const expected_vectors = 3;
        
        if (stats2.node_count == expected_nodes and 
            stats2.edge_count == expected_edges and 
            stats2.vector_count == expected_vectors) {
            std.debug.print("\n✅ SUCCESS: All data persisted correctly via exit snapshot!\n", .{});
        } else {
            std.debug.print("\n❌ FAILURE: Data not persisted correctly\n", .{});
            std.debug.print("  Expected: {} nodes, {} edges, {} vectors\n", .{expected_nodes, expected_edges, expected_vectors});
            std.debug.print("  Got: {} nodes, {} edges, {} vectors\n", .{stats2.node_count, stats2.edge_count, stats2.vector_count});
        }
        
        std.debug.print("\n📁 Check test_exit_data/ for created snapshot files\n", .{});
    }
    
    std.debug.print("\n🎉 Exit snapshot test complete!\n", .{});
} 