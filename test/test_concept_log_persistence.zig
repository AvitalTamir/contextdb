const std = @import("std");
const memora = @import("memora");
const testing = std.testing;

test "concept nodes and edges are written to log during MCP operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Clean up test data
    std.fs.cwd().deleteTree("test_concept_log_persistence") catch {};
    defer std.fs.cwd().deleteTree("test_concept_log_persistence") catch {};

    std.debug.print("\n=== Testing Concept Log Persistence During MCP Operations ===\n", .{});

    const config = memora.MemoraConfig{
        .data_path = "test_concept_log_persistence",
        .auto_snapshot_interval = null,
        .enable_persistent_indexes = false,
    };

    var db = try memora.Memora.init(allocator, config, null);
    defer db.deinit();

    var mcp_srv = memora.mcp_server.McpServer.init(allocator, &db, 0);
    defer mcp_srv.deinit();

    std.debug.print("\n--- Phase 1: Store memory via MCP server (simulating real usage) ---\n", .{});

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

    for (concepts.items) |concept| {
        const concept_id = mcp_srv.generateConceptId(concept);
        try concept_ids.append(concept_id);
        
        // Create concept node (like MCP server does)
        const concept_node = memora.types.Node.init(concept_id, concept);
        try db.insertNode(concept_node);
        
        // Create relationship from memory to concept (like MCP server does)
        const memory_to_concept_edge = memora.types.Edge.init(memory_id, concept_id, memora.types.EdgeKind.related);
        try db.insertEdge(memory_to_concept_edge);
        
        std.debug.print("  ✅ Created concept '{s}': {} -> {}\n", .{ concept, memory_id, concept_id });
    }

    std.debug.print("\n--- Phase 2: Analyze what's in the log ---\n", .{});

    // Count different types of entries in the log
    var memory_content_entries: u32 = 0;
    var node_entries: u32 = 0;
    var edge_entries: u32 = 0;
    var vector_entries: u32 = 0;
    var concept_node_entries: u32 = 0;
    var concept_edge_entries: u32 = 0;

    var iter = db.append_log.iterator();
    while (iter.next()) |entry| {
        switch (entry.getEntryType()) {
            .memory_content => {
                memory_content_entries += 1;
                if (entry.asMemoryContent()) |mem_content| {
                    std.debug.print("  📝 Memory content entry: {} -> \"{s}\"\n", .{ mem_content.memory_id, mem_content.content });
                }
            },
            .node => {
                node_entries += 1;
                if (entry.asNode()) |node| {
                    if (node.id >= 0x8000000000000000) {
                        concept_node_entries += 1;
                        std.debug.print("  🏷️  Concept node entry: {} -> \"{s}\"\n", .{ node.id, node.getLabelAsString() });
                    } else {
                        std.debug.print("  📦 Memory node entry: {} -> \"{s}\"\n", .{ node.id, node.getLabelAsString() });
                    }
                }
            },
            .edge => {
                edge_entries += 1;
                if (entry.asEdge()) |edge| {
                    if (edge.from >= 0x8000000000000000 or edge.to >= 0x8000000000000000) {
                        concept_edge_entries += 1;
                        std.debug.print("  🔗 Concept edge entry: {} -> {} ({})\n", .{ edge.from, edge.to, edge.getKind() });
                    } else {
                        std.debug.print("  🔗 Memory edge entry: {} -> {} ({})\n", .{ edge.from, edge.to, edge.getKind() });
                    }
                }
            },
            .vector => {
                vector_entries += 1;
                if (entry.asVector()) |vector| {
                    std.debug.print("  🎯 Vector entry: {}\n", .{vector.id});
                }
            },
        }
    }

    std.debug.print("\n📊 Log Analysis Summary:\n", .{});
    std.debug.print("  • Memory content entries: {}\n", .{memory_content_entries});
    std.debug.print("  • Total node entries: {}\n", .{node_entries});
    std.debug.print("  • Total edge entries: {}\n", .{edge_entries});
    std.debug.print("  • Vector entries: {}\n", .{vector_entries});
    std.debug.print("  • Concept node entries: {}\n", .{concept_node_entries});
    std.debug.print("  • Concept edge entries: {}\n", .{concept_edge_entries});

    std.debug.print("\n--- Phase 3: Test log replay (simulating restart) ---\n", .{});

    // Clear in-memory indexes to simulate restart
    db.graph_index.deinit();
    db.vector_index.deinit();
    
    db.graph_index = memora.graph.GraphIndex.init(allocator);
    db.vector_index = memora.vector.VectorIndex.init(allocator);

    std.debug.print("🔄 Cleared in-memory indexes, replaying from log...\n", .{});

    // Replay from log (this is what happens during restart)
    try db.replayFromLog();

    std.debug.print("\n📊 State after log replay:\n", .{});
    std.debug.print("  • Graph nodes: {}\n", .{db.graph_index.nodes.count()});
    std.debug.print("  • Graph edges: {}\n", .{db.graph_index.outgoing_edges.count()});
    std.debug.print("  • Vectors: {}\n", .{db.vector_index.getVectorCount()});

    // Check if concept nodes were restored from log
    var restored_concept_nodes: u32 = 0;
    var restored_concept_edges: u32 = 0;

    for (concept_ids.items) |concept_id| {
        if (db.graph_index.getNode(concept_id)) |node| {
            std.debug.print("  ✅ Concept node restored from log: '{s}' ({})\n", .{ node.getLabelAsString(), concept_id });
            restored_concept_nodes += 1;

            // Check if edges were restored
            if (db.graph_index.getIncomingEdges(concept_id)) |edges| {
                for (edges) |edge| {
                    if (edge.from == memory_id and edge.getKind() == memora.types.EdgeKind.related) {
                        std.debug.print("    ✅ Concept edge restored from log: {} -> {}\n", .{ edge.from, edge.to });
                        restored_concept_edges += 1;
                        break;
                    }
                }
            }
        } else {
            std.debug.print("  ❌ Concept node missing after log replay: {}\n", .{concept_id});
        }
    }

    std.debug.print("\n🎯 Final Results:\n", .{});
    std.debug.print("  • Expected concept nodes: {}\n", .{concept_ids.items.len});
    std.debug.print("  • Restored concept nodes: {}\n", .{restored_concept_nodes});
    std.debug.print("  • Expected concept edges: {}\n", .{concept_ids.items.len});
    std.debug.print("  • Restored concept edges: {}\n", .{restored_concept_edges});

    // The test should pass if concepts are properly logged and restored
    if (concept_node_entries == 0) {
        std.debug.print("\n❌ ISSUE CONFIRMED: Concept nodes are NOT being written to log!\n", .{});
        std.debug.print("   This explains why concepts don't survive restarts.\n", .{});
        return error.ConceptNodesNotLogged;
    }

    if (concept_edge_entries == 0) {
        std.debug.print("\n❌ ISSUE CONFIRMED: Concept edges are NOT being written to log!\n", .{});
        std.debug.print("   This explains why concept relationships don't survive restarts.\n", .{});
        return error.ConceptEdgesNotLogged;
    }

    if (restored_concept_nodes != concept_ids.items.len) {
        std.debug.print("\n❌ ISSUE: Not all concept nodes were restored from log!\n", .{});
        return error.ConceptNodesNotRestored;
    }

    if (restored_concept_edges != concept_ids.items.len) {
        std.debug.print("\n❌ ISSUE: Not all concept edges were restored from log!\n", .{});
        return error.ConceptEdgesNotRestored;
    }

    std.debug.print("\n🎉 SUCCESS: All concepts properly logged and restored!\n", .{});
} 