const std = @import("std");
const memora = @import("memora");
const memory_manager = @import("../src/memory_manager.zig");
const config_mod = @import("../src/config.zig");

test "debug auto-snapshot with real config values" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Auto-Snapshot Debug Test ===\n", .{});

    // Clean up test data
    const test_path = "test_auto_snapshot_debug";
    std.fs.cwd().deleteTree(test_path) catch {};
    defer std.fs.cwd().deleteTree(test_path) catch {};

    // Use config with the same auto_interval as memora.conf (50)
    const global_config = config_mod.Config{
        .snapshot_auto_interval = 50,
    };

    std.debug.print("Loaded config - snapshot_auto_interval: {}\n", .{global_config.snapshot_auto_interval});

    // Create Memora config
    const memora_config = memora.MemoraConfig{
        .data_path = test_path,
        .enable_persistent_indexes = false,
    };

    // Initialize database with real config
    var memora_db = try memora.Memora.init(allocator, memora_config, global_config);
    defer memora_db.deinit();

    std.debug.print("Database initialized with auto_interval: {}\n", .{memora_db.snapshot_manager.config.auto_interval});

    // Initialize memory manager
    var mem_manager = memory_manager.MemoryManager.init(allocator, &memora_db);
    defer mem_manager.deinit();

    // Check initial state
    const initial_entry_count = memora_db.append_log.getEntryCount();
    std.debug.print("Initial log entries: {}\n", .{initial_entry_count});

    var initial_snapshots = try memora_db.snapshot_manager.listSnapshots();
    defer initial_snapshots.deinit();
    std.debug.print("Initial snapshots: {}\n", .{initial_snapshots.items.len});

    // Create exactly the number of entries needed to trigger auto-snapshot
    const auto_interval = memora_db.snapshot_manager.config.auto_interval;
    const target_entries = auto_interval;
    
    std.debug.print("Creating {} entries to trigger auto-snapshot...\n", .{target_entries});

    // Create concept nodes and edges to reach the target
    var entry_count: u32 = 0;
    while (entry_count < target_entries) {
        // Create a concept node
        const concept_id: u64 = @as(u64, 0x8000000000000000) + entry_count;
        const concept_name = try std.fmt.allocPrint(allocator, "concept_{}", .{entry_count});
        defer allocator.free(concept_name);
        
        const node = memora.types.Node.init(concept_id, concept_name);
        try memora_db.insertNode(node);
        entry_count += 1;
        
        const current_entries = memora_db.append_log.getEntryCount();
        std.debug.print("Entry {}: log_entries={}, target={}\n", .{entry_count, current_entries, target_entries});
        
        // Check if auto-snapshot should have been triggered
        if (current_entries > 0 and current_entries % auto_interval == 0) {
            std.debug.print("*** AUTO-SNAPSHOT SHOULD TRIGGER NOW! ***\n", .{});
            
            // Check if snapshot was actually created
            var current_snapshots = try memora_db.snapshot_manager.listSnapshots();
            defer current_snapshots.deinit();
            std.debug.print("Snapshots after entry {}: {}\n", .{entry_count, current_snapshots.items.len});
            
            if (current_snapshots.items.len > initial_snapshots.items.len) {
                std.debug.print("✅ Auto-snapshot was created!\n", .{});
            } else {
                std.debug.print("❌ Auto-snapshot was NOT created!\n", .{});
            }
        }
        
        if (entry_count >= target_entries) break;
    }

    // Final check
    const final_entry_count = memora_db.append_log.getEntryCount();
    var final_snapshots = try memora_db.snapshot_manager.listSnapshots();
    defer final_snapshots.deinit();
    
    std.debug.print("\n=== Final Results ===\n", .{});
    std.debug.print("Final log entries: {}\n", .{final_entry_count});
    std.debug.print("Final snapshots: {}\n", .{final_snapshots.items.len});
    std.debug.print("Auto-interval: {}\n", .{auto_interval});
    std.debug.print("Expected snapshots: {}\n", .{final_entry_count / auto_interval});
    
    // Test the auto-snapshot logic manually
    std.debug.print("\n=== Manual Auto-Snapshot Test ===\n", .{});
    const entries_before_manual = memora_db.append_log.getEntryCount();
    std.debug.print("Entries before manual test: {}\n", .{entries_before_manual});
    std.debug.print("entries_before_manual % auto_interval = {}\n", .{entries_before_manual % auto_interval});
    
    if (entries_before_manual > 0 and entries_before_manual % auto_interval == 0) {
        std.debug.print("Condition met - calling autoSnapshot() manually...\n", .{});
        try memora_db.autoSnapshot();
        
        var snapshots_after_manual = try memora_db.snapshot_manager.listSnapshots();
        defer snapshots_after_manual.deinit();
        std.debug.print("Snapshots after manual call: {}\n", .{snapshots_after_manual.items.len});
    } else {
        std.debug.print("Condition NOT met for manual auto-snapshot\n", .{});
    }
}

test "debug auto-snapshot with smaller interval" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Auto-Snapshot Debug Test (Small Interval) ===\n", .{});

    // Clean up test data
    const test_path = "test_auto_snapshot_small";
    std.fs.cwd().deleteTree(test_path) catch {};
    defer std.fs.cwd().deleteTree(test_path) catch {};

    // Create custom config with small interval
    const custom_config = config_mod.Config{
        .snapshot_auto_interval = 3, // Very small for testing
    };

    // Create Memora config
    const memora_config = memora.MemoraConfig{
        .data_path = test_path,
        .enable_persistent_indexes = false,
    };

    // Initialize database with custom config
    var memora_db = try memora.Memora.init(allocator, memora_config, custom_config);
    defer memora_db.deinit();

    std.debug.print("Database initialized with auto_interval: {}\n", .{memora_db.snapshot_manager.config.auto_interval});

    // Check initial state
    var initial_snapshots = try memora_db.snapshot_manager.listSnapshots();
    defer initial_snapshots.deinit();
    std.debug.print("Initial snapshots: {}\n", .{initial_snapshots.items.len});

    // Create entries one by one and monitor auto-snapshots
    for (0..10) |i| {
        const concept_id: u64 = @as(u64, 0x8000000000000000) + i;
        const concept_name = try std.fmt.allocPrint(allocator, "concept_{}", .{i});
        defer allocator.free(concept_name);
        
        std.debug.print("\n--- Creating entry {} ---\n", .{i + 1});
        const node = memora.types.Node.init(concept_id, concept_name);
        try memora_db.insertNode(node);
        
        const current_entries = memora_db.append_log.getEntryCount();
        std.debug.print("Log entries after insert: {}\n", .{current_entries});
        std.debug.print("current_entries % auto_interval = {} % {} = {}\n", .{current_entries, memora_db.snapshot_manager.config.auto_interval, current_entries % memora_db.snapshot_manager.config.auto_interval});
        
        var current_snapshots = try memora_db.snapshot_manager.listSnapshots();
        defer current_snapshots.deinit();
        std.debug.print("Snapshots after insert: {}\n", .{current_snapshots.items.len});
        
        if (current_entries > 0 and current_entries % memora_db.snapshot_manager.config.auto_interval == 0) {
            std.debug.print("*** AUTO-SNAPSHOT SHOULD HAVE TRIGGERED! ***\n", .{});
        }
    }

    // Final summary
    const final_entry_count = memora_db.append_log.getEntryCount();
    var final_snapshots = try memora_db.snapshot_manager.listSnapshots();
    defer final_snapshots.deinit();
    
    std.debug.print("\n=== Final Summary ===\n", .{});
    std.debug.print("Final log entries: {}\n", .{final_entry_count});
    std.debug.print("Final snapshots: {}\n", .{final_snapshots.items.len});
    std.debug.print("Expected auto-snapshots: {}\n", .{final_entry_count / 3});
} 