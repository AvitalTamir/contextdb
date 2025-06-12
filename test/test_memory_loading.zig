const std = @import("std");
const memora = @import("memora");
const memory_manager = @import("../src/memory_manager.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Testing Memory Loading from All Snapshots ===\n", .{});

    // Use the actual MCP data directory
    const config = memora.MemoraConfig{
        .data_path = "memora_mcp_data",
        .auto_snapshot_interval = 100,
        .enable_persistent_indexes = false,
    };

    // Initialize database
    var memora_db = try memora.Memora.init(allocator, config, null);
    defer memora_db.deinit();

    std.debug.print("Database initialized\n", .{});

    // List all snapshots
    const all_snapshots = try memora_db.snapshot_manager.listSnapshots();
    defer all_snapshots.deinit();
    
    std.debug.print("Found {} snapshots: ", .{all_snapshots.items.len});
    for (all_snapshots.items) |snapshot_id| {
        std.debug.print("{} ", .{snapshot_id});
    }
    std.debug.print("\n", .{});

    // Test loading from each snapshot individually
    var total_memories: u32 = 0;
    for (all_snapshots.items) |snapshot_id| {
        std.debug.print("\n--- Testing Snapshot {} ---\n", .{snapshot_id});
        
        if (try memora_db.snapshot_manager.loadSnapshot(snapshot_id)) |snapshot_info| {
            defer snapshot_info.deinit();
            
            std.debug.print("Snapshot {} metadata:\n", .{snapshot_id});
            std.debug.print("  Memory content files: {}\n", .{snapshot_info.memory_content_files.items.len});
            for (snapshot_info.memory_content_files.items) |file| {
                std.debug.print("    - {s}\n", .{file});
            }
            std.debug.print("  Memory count: {}\n", .{snapshot_info.counts.memory_contents});
            
            if (snapshot_info.memory_content_files.items.len > 0) {
                const memory_contents = try memora_db.snapshot_manager.loadMemoryContents(&snapshot_info);
                defer {
                    // Free the allocated content strings
                    for (memory_contents.items) |memory_content| {
                        allocator.free(memory_content.content);
                    }
                    memory_contents.deinit();
                }
                
                std.debug.print("  Loaded {} memories from snapshot {}:\n", .{memory_contents.items.len, snapshot_id});
                for (memory_contents.items) |memory_content| {
                    std.debug.print("    Memory {}: {s}\n", .{memory_content.memory_id, memory_content.content});
                    total_memories += 1;
                }
            }
        } else {
            std.debug.print("Failed to load snapshot {}\n", .{snapshot_id});
        }
    }

    std.debug.print("\n=== Total memories found across all snapshots: {} ===\n", .{total_memories});

    // Now test the MemoryManager loading
    std.debug.print("\n=== Testing MemoryManager Loading ===\n", .{});
    
    var mem_manager = memory_manager.MemoryManager.init(allocator, &memora_db);
    defer mem_manager.deinit();
    
    std.debug.print("MemoryManager initialized\n", .{});
    std.debug.print("Memory content cache size: {}\n", .{mem_manager.memory_content.count()});
    
    // List all memories in the cache
    var content_iter = mem_manager.memory_content.iterator();
    while (content_iter.next()) |entry| {
        const memory_id = entry.key_ptr.*;
        const content = entry.value_ptr.*;
        std.debug.print("  Memory {}: {s}\n", .{memory_id, content});
    }
    
    std.debug.print("\n=== Test Complete ===\n", .{});
} 