const std = @import("std");
const memora = @import("src/main.zig");
const memory_manager = @import("src/memory_manager.zig");
const memory_types = @import("src/memory_types.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🧠 Testing Memory Restoration Fix\n", .{});
    std.debug.print("==================================\n\n", .{});

    // Clean up any existing test data
    std.fs.cwd().deleteTree("test_memory_restoration") catch {};
    defer std.fs.cwd().deleteTree("test_memory_restoration") catch {};

    // Initialize Memora
    const config = memora.MemoraConfig{
        .data_path = "test_memory_restoration",
        .enable_persistent_indexes = false,
        .auto_snapshot_interval = null,
        .s3_bucket = null,
        .s3_region = null,
        .s3_prefix = null,
    };

    var db = try memora.Memora.init(allocator, config, null);
    defer db.deinit();

    // Test Phase 1: Add memories and create snapshot
    {
        // Initialize MemoryManager
        var mem_manager = memory_manager.MemoryManager.init(allocator, &db);
        defer mem_manager.deinit();

        std.debug.print("📝 Step 1: Adding test memories...\n", .{});
        
        // Add some test memories
        const memory1_id = try mem_manager.storeMemory(
            memory_types.MemoryType.experience,
            "User prefers concise explanations",
            .{ .confidence = memory_types.MemoryConfidence.high, .importance = memory_types.MemoryImportance.high }
        );
        
        const memory2_id = try mem_manager.storeMemory(
            memory_types.MemoryType.preference,
            "User likes technical details",
            .{ .confidence = memory_types.MemoryConfidence.medium, .importance = memory_types.MemoryImportance.medium }
        );
        
        const memory3_id = try mem_manager.storeMemory(
            memory_types.MemoryType.fact,
            "User is learning Zig programming",
            .{ .confidence = memory_types.MemoryConfidence.high, .importance = memory_types.MemoryImportance.high }
        );

        std.debug.print("✅ Added 3 memories: {}, {}, {}\n", .{ memory1_id, memory2_id, memory3_id });

        // Verify memories exist
        std.debug.print("\n📖 Step 2: Verifying memories before snapshot...\n", .{});
        for ([_]u64{ memory1_id, memory2_id, memory3_id }) |mem_id| {
            if (try mem_manager.getMemory(mem_id)) |memory| {
                std.debug.print("  Memory {}: \"{s}\"\n", .{ mem_id, memory.getContentAsString() });
            } else {
                std.debug.print("  ❌ Memory {} not found!\n", .{mem_id});
            }
        }

        std.debug.print("\n📸 Step 3: Creating snapshot with proper memory content...\n", .{});
        
        // Create snapshot using the new method that gets memory content from MemoryManager
        const memory_contents = try db.getAllMemoryContentFromManager(&mem_manager);
        defer {
            for (memory_contents.items) |memory_content| {
                allocator.free(memory_content.content);
            }
            memory_contents.deinit();
        }
        
        const vectors = try db.getAllVectors();
        defer vectors.deinit();
        
        const nodes = try db.getAllNodes();
        defer nodes.deinit();
        
        const edges = try db.getAllEdges();
        defer edges.deinit();
        
        var snapshot_info = try db.snapshot_manager.createSnapshot(vectors.items, nodes.items, edges.items, memory_contents.items);
        defer snapshot_info.deinit();
        
        std.debug.print("✅ Snapshot {} created with {} memory contents\n", .{ snapshot_info.snapshot_id, memory_contents.items.len });

        // Clear the log to simulate restart
        try db.append_log.clear();
        std.debug.print("🗑️  Cleared append log to simulate restart\n", .{});
        
        // MemoryManager will be deinitialized here automatically
    }

    std.debug.print("\n🔄 Step 4: Simulating restart - creating new MemoryManager...\n", .{});
    
    // Test Phase 2: Restart and verify restoration
    {
        // Create new MemoryManager to simulate restart
        var mem_manager = memory_manager.MemoryManager.init(allocator, &db);
        defer mem_manager.deinit();

        std.debug.print("\n🔍 Step 5: Verifying memories after restart...\n", .{});
        var restored_count: u32 = 0;
        var placeholder_count: u32 = 0;
        
        for ([_]u64{ 1, 2, 3 }) |mem_id| {
            if (try mem_manager.getMemory(mem_id)) |memory| {
                const content = memory.getContentAsString();
                if (std.mem.startsWith(u8, content, "[Recovered memory ID")) {
                    placeholder_count += 1;
                    std.debug.print("  ❌ Memory {}: \"{s}\" (PLACEHOLDER!)\n", .{ mem_id, content });
                } else {
                    restored_count += 1;
                    std.debug.print("  ✅ Memory {}: \"{s}\" (RESTORED!)\n", .{ mem_id, content });
                }
            } else {
                std.debug.print("  ❌ Memory {} not found!\n", .{mem_id});
            }
        }

        std.debug.print("\n📊 Results:\n", .{});
        std.debug.print("  • Restored memories: {}\n", .{restored_count});
        std.debug.print("  • Placeholder memories: {}\n", .{placeholder_count});
        std.debug.print("  • Missing memories: {}\n", .{3 - restored_count - placeholder_count});

        if (restored_count == 3 and placeholder_count == 0) {
            std.debug.print("\n🎉 SUCCESS: All memories restored correctly!\n", .{});
        } else {
            std.debug.print("\n❌ FAILURE: Memory restoration still has issues\n", .{});
        }
        
        // MemoryManager will be deinitialized here automatically
    }
} 