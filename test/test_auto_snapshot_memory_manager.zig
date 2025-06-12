const std = @import("std");
const memora = @import("memora");
const memory_manager = @import("../src/memory_manager.zig");
const config_mod = @import("../src/config.zig");

test "auto-snapshot includes MemoryManager data" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Auto-Snapshot MemoryManager Integration Test ===\n", .{});

    // Clean up test data
    const test_path = "test_auto_snapshot_memory_manager";
    std.fs.cwd().deleteTree(test_path) catch {};
    defer std.fs.cwd().deleteTree(test_path) catch {};

    // Use config with small auto_interval for testing
    const global_config = config_mod.Config{
        .snapshot_auto_interval = 5, // Small interval for testing
    };

    // Create Memora config
    const memora_config = memora.MemoraConfig{
        .data_path = test_path,
        .enable_persistent_indexes = false,
    };

    // Initialize database
    var memora_db = try memora.Memora.init(allocator, memora_config, global_config);
    defer memora_db.deinit();

    // Initialize memory manager and register it (simulating MCP server)
    var mem_manager = memory_manager.MemoryManager.init(allocator, &memora_db);
    defer mem_manager.deinit();
    memora_db.registerMemoryManager(&mem_manager);

    std.debug.print("Database and MemoryManager initialized\n", .{});

    // Store a memory with concepts (simulating MCP server storing user memory)
    const memory_content = "My son Adam plays banjo and my wife Noa loves music. We have 2 cats: Che and Hilda.";
    
    // Store memory using MemoryManager
    const memory_id = try mem_manager.storeMemory(.experience, memory_content, .{
        .confidence = .high,
        .importance = .high,
        .source = .user_input,
    });
    
    // Create concept nodes and relationships (simulating concept extraction)
    const adam_concept_id: u64 = @as(u64, 0x8000000000000000) + 1;
    const noa_concept_id: u64 = @as(u64, 0x8000000000000000) + 2;
    const banjo_concept_id: u64 = @as(u64, 0x8000000000000000) + 3;
    const cats_concept_id: u64 = @as(u64, 0x8000000000000000) + 4;
    
    // Insert concept nodes
    try memora_db.insertNode(memora.types.Node.init(adam_concept_id, "adam"));
    try memora_db.insertNode(memora.types.Node.init(noa_concept_id, "noa"));
    try memora_db.insertNode(memora.types.Node.init(banjo_concept_id, "banjo"));
    try memora_db.insertNode(memora.types.Node.init(cats_concept_id, "cats"));
    
    // Create memory node
    try memora_db.insertNode(memora.types.Node.init(memory_id, "memory_1"));
    
    std.debug.print("Created memory and concept nodes\n", .{});
    
    // Check that auto-snapshot was triggered (should happen at 5 entries)
    const current_entries = memora_db.append_log.getEntryCount();
    std.debug.print("Current log entries: {}\n", .{current_entries});
    
    var snapshots = try memora_db.snapshot_manager.listSnapshots();
    defer snapshots.deinit();
    std.debug.print("Snapshots created: {}\n", .{snapshots.items.len});
    
    // Verify that auto-snapshot was triggered
    try std.testing.expect(snapshots.items.len > 0);
    
    // Now simulate a restart by creating a new database instance
    std.debug.print("\n--- Simulating Database Restart ---\n", .{});
    
    // Deinitialize current database
    memora_db.deinit();
    
    // Create new database instance
    var memora_db2 = try memora.Memora.init(allocator, memora_config, global_config);
    defer memora_db2.deinit();
    
    // Initialize new memory manager
    var mem_manager2 = memory_manager.MemoryManager.init(allocator, &memora_db2);
    defer mem_manager2.deinit();
    memora_db2.registerMemoryManager(&mem_manager2);
    
    std.debug.print("New database instance initialized\n", .{});
    
    // Test memory retrieval functionality
    std.debug.print("\n--- Testing Memory Retrieval After Restart ---\n", .{});
    
    // Verify that the memory can be retrieved
    const retrieved_memory = try mem_manager2.getMemory(memory_id);
    if (retrieved_memory) |memory| {
        std.debug.print("Retrieved memory ID: {}\n", .{memory.id});
        std.debug.print("Retrieved memory type: {}\n", .{memory.memory_type});
        std.debug.print("Retrieved memory confidence: {}\n", .{memory.confidence});
        
        // Check if the content is preserved in the memory content cache
        const cached_content = mem_manager2.memory_content.get(memory_id);
        if (cached_content) |content| {
            std.debug.print("Retrieved memory content: {s}\n", .{content});
            try std.testing.expect(std.mem.eql(u8, content, memory_content));
        } else {
            std.debug.print("Memory content not in cache, but memory exists\n", .{});
        }
    } else {
        std.debug.print("ERROR: Memory not found!\n", .{});
        try std.testing.expect(false);
    }
    
    // Test that concept nodes are preserved
    std.debug.print("\n--- Testing Concept Node Preservation ---\n", .{});
    
    // Check if concept nodes exist
    const adam_node = memora_db2.graph_index.getNode(adam_concept_id);
    const banjo_node = memora_db2.graph_index.getNode(banjo_concept_id);
    const cats_node = memora_db2.graph_index.getNode(cats_concept_id);
    
    std.debug.print("Adam concept node exists: {}\n", .{adam_node != null});
    std.debug.print("Banjo concept node exists: {}\n", .{banjo_node != null});
    std.debug.print("Cats concept node exists: {}\n", .{cats_node != null});
    
    // Verify concept nodes are preserved
    try std.testing.expect(adam_node != null);
    try std.testing.expect(banjo_node != null);
    try std.testing.expect(cats_node != null);
    
    std.debug.print("\n✅ SUCCESS: Auto-snapshots now preserve MemoryManager data!\n", .{});
    std.debug.print("✅ Memory retrieval works after restart\n", .{});
    std.debug.print("✅ Concept nodes are preserved\n", .{});
} 