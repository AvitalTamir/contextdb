const std = @import("std");
const memora = @import("memora");
const testing = std.testing;

test "auto-snapshots capture concept nodes and edges correctly" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Clean up test data
    std.fs.cwd().deleteTree("test_auto_snapshot_concepts") catch {};
    defer std.fs.cwd().deleteTree("test_auto_snapshot_concepts") catch {};

    std.debug.print("\n=== Testing Auto-Snapshot Concept Persistence ===\n", .{});

    // Configure with very low auto-snapshot interval to trigger snapshots quickly
    const config = memora.MemoraConfig{
        .data_path = "test_auto_snapshot_concepts",
        .auto_snapshot_interval = 5, // Trigger snapshot every 5 log entries
        .enable_persistent_indexes = false,
    };

    var db = try memora.Memora.init(allocator, config, null);
    defer db.deinit();

    var mcp_srv = memora.mcp_server.McpServer.init(allocator, &db, 0);
    defer mcp_srv.deinit();

    std.debug.print("\n--- Phase 1: Create concepts and trigger auto-snapshots ---\n", .{});

    // Store a memory that will generate concepts
    const memory_id = try mcp_srv.memory_manager.storeMemory(
        memora.memory_types.MemoryType.experience,
        "User loves playing banjo and learning Zig programming language",
        .{ 
            .confidence = memora.memory_types.MemoryConfidence.high, 
            .importance = memora.memory_types.MemoryImportance.high,
            .create_embedding = true,
        }
    );
    std.debug.print("✅ Stored memory {} via MemoryManager\n", .{memory_id});

    // Extract concepts and create relationships like the MCP server does
    const concepts = try mcp_srv.extractConcepts("User loves playing banjo and learning Zig programming language");
    defer {
        for (concepts.items) |concept| {
            allocator.free(concept);
        }
        concepts.deinit();
    }

    var concept_ids = std.ArrayList(u64).init(allocator);
    defer concept_ids.deinit();

    // Create concepts one by one to trigger auto-snapshots
    for (concepts.items) |concept| {
        const concept_id = mcp_srv.generateConceptId(concept);
        try concept_ids.append(concept_id);
        
        // Create concept node (like MCP server does) - this should trigger auto-snapshot
        const concept_node = memora.types.Node.init(concept_id, concept);
        try db.insertNode(concept_node);
        
        // Create relationship from memory to concept (like MCP server does) - this should trigger auto-snapshot
        const memory_to_concept_edge = memora.types.Edge.init(memory_id, concept_id, memora.types.EdgeKind.related);
        try db.insertEdge(memory_to_concept_edge);
        
        std.debug.print("  ✅ Created concept '{s}': {} -> {} (log entries: {})\n", .{ concept, memory_id, concept_id, db.append_log.getEntryCount() });
    }

    std.debug.print("\n📊 Final state:\n", .{});
    std.debug.print("  • Graph nodes: {}\n", .{db.graph_index.nodes.count()});
    std.debug.print("  • Graph edges: {}\n", .{db.graph_index.outgoing_edges.count()});
    std.debug.print("  • Vectors: {}\n", .{db.vector_index.getVectorCount()});
    std.debug.print("  • Log entries: {}\n", .{db.append_log.getEntryCount()});

    // Check if auto-snapshots were created
    const snapshots = try db.snapshot_manager.listSnapshots();
    defer snapshots.deinit();
    
    std.debug.print("  • Auto-snapshots created: {}\n", .{snapshots.items.len});
    
    if (snapshots.items.len == 0) {
        std.debug.print("❌ No auto-snapshots were created! This might explain the persistence issue.\n", .{});
        return error.NoAutoSnapshots;
    }

    // Analyze the latest auto-snapshot
    const latest_snapshot_id = snapshots.items[snapshots.items.len - 1];
    std.debug.print("\n🔍 Analyzing latest auto-snapshot {}...\n", .{latest_snapshot_id});

    // Load the snapshot info
    const latest_snapshot_info = (try db.snapshot_manager.loadSnapshot(latest_snapshot_id)).?;
    defer latest_snapshot_info.deinit();

    // Load nodes from the auto-snapshot
    const snapshot_nodes = try db.snapshot_manager.loadNodes(&latest_snapshot_info);
    defer snapshot_nodes.deinit();
    
    // Load edges from the auto-snapshot
    const snapshot_edges = try db.snapshot_manager.loadEdges(&latest_snapshot_info);
    defer snapshot_edges.deinit();

    std.debug.print("  • Auto-snapshot contains {} nodes\n", .{snapshot_nodes.items.len});
    std.debug.print("  • Auto-snapshot contains {} edges\n", .{snapshot_edges.items.len});

    // Count concept nodes and edges in auto-snapshot
    var concept_nodes_in_snapshot: u32 = 0;
    var concept_edges_in_snapshot: u32 = 0;

    for (snapshot_nodes.items) |node| {
        if (node.id >= 0x8000000000000000) {
            concept_nodes_in_snapshot += 1;
            std.debug.print("  🏷️  Auto-snapshot contains concept node: '{s}' ({})\n", .{ node.getLabelAsString(), node.id });
        }
    }

    for (snapshot_edges.items) |edge| {
        if (edge.from >= 0x8000000000000000 or edge.to >= 0x8000000000000000) {
            concept_edges_in_snapshot += 1;
            std.debug.print("  🔗 Auto-snapshot contains concept edge: {} -> {}\n", .{ edge.from, edge.to });
        }
    }

    std.debug.print("  • Concept nodes in auto-snapshot: {}\n", .{concept_nodes_in_snapshot});
    std.debug.print("  • Concept edges in auto-snapshot: {}\n", .{concept_edges_in_snapshot});

    if (concept_nodes_in_snapshot != concept_ids.items.len) {
        std.debug.print("❌ ISSUE: Not all concept nodes were saved to auto-snapshot!\n", .{});
        return error.ConceptNodesNotInAutoSnapshot;
    }

    if (concept_edges_in_snapshot != concept_ids.items.len) {
        std.debug.print("❌ ISSUE: Not all concept edges were saved to auto-snapshot!\n", .{});
        return error.ConceptEdgesNotInAutoSnapshot;
    }

    std.debug.print("\n🎉 SUCCESS: Auto-snapshots correctly capture concept nodes and edges!\n", .{});
} 