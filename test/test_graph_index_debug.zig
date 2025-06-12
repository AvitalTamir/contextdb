const std = @import("std");
const memora = @import("memora");
const memory_manager = @import("../src/memory_manager.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Debugging Graph Index vs MemoryManager Mismatch ===\n", .{});

    // Use the actual MCP data directory
    const config = memora.MemoraConfig{
        .data_path = "memora_mcp_data",
        .auto_snapshot_interval = 100,
        .enable_persistent_indexes = false,
    };

    // Initialize database
    var memora_db = try memora.Memora.init(allocator, config, null);
    defer memora_db.deinit();

    // Initialize MemoryManager
    var mem_manager = memory_manager.MemoryManager.init(allocator, &memora_db);
    defer mem_manager.deinit();

    std.debug.print("Database and MemoryManager initialized\n", .{});

    // Check what's in the MemoryManager cache
    std.debug.print("\n=== MemoryManager Cache Contents ===\n", .{});
    std.debug.print("Memory content cache size: {}\n", .{mem_manager.memory_content.count()});
    
    var content_iter = mem_manager.memory_content.iterator();
    while (content_iter.next()) |entry| {
        const memory_id = entry.key_ptr.*;
        const content = entry.value_ptr.*;
        std.debug.print("  Memory {}: {s}\n", .{memory_id, content});
    }

    // Check what's in the graph index
    std.debug.print("\n=== Graph Index Node Contents ===\n", .{});
    std.debug.print("Graph index node count: {}\n", .{memora_db.graph_index.nodes.count()});
    
    var node_iter = memora_db.graph_index.nodes.iterator();
    while (node_iter.next()) |entry| {
        const node_id = entry.key_ptr.*;
        const node = entry.value_ptr.*;
        const is_memory_node = node_id < 0x8000000000000000;
        std.debug.print("  Node {}: {s} (memory_node: {})\n", .{node_id, node.getLabelAsString(), is_memory_node});
    }

    // Check for missing nodes - memories in cache but not in graph
    std.debug.print("\n=== Missing Nodes Analysis ===\n", .{});
    var missing_count: u32 = 0;
    content_iter = mem_manager.memory_content.iterator();
    while (content_iter.next()) |entry| {
        const memory_id = entry.key_ptr.*;
        if (memora_db.graph_index.getNode(memory_id) == null) {
            std.debug.print("  MISSING: Memory {} exists in cache but not in graph index\n", .{memory_id});
            missing_count += 1;
        }
    }
    
    if (missing_count == 0) {
        std.debug.print("  ✅ All memories in cache are also in graph index\n", .{});
    } else {
        std.debug.print("  ❌ {} memories are missing from graph index\n", .{missing_count});
    }

    // Check for orphaned nodes - nodes in graph but not in cache
    std.debug.print("\n=== Orphaned Nodes Analysis ===\n", .{});
    var orphaned_count: u32 = 0;
    node_iter = memora_db.graph_index.nodes.iterator();
    while (node_iter.next()) |entry| {
        const node_id = entry.key_ptr.*;
        const is_memory_node = node_id < 0x8000000000000000;
        if (is_memory_node and !mem_manager.memory_content.contains(node_id)) {
            std.debug.print("  ORPHANED: Node {} exists in graph but not in memory cache\n", .{node_id});
            orphaned_count += 1;
        }
    }
    
    if (orphaned_count == 0) {
        std.debug.print("  ✅ All memory nodes in graph have corresponding cache entries\n", .{});
    } else {
        std.debug.print("  ❌ {} memory nodes are orphaned (no cache entry)\n", .{orphaned_count});
    }

    std.debug.print("\n=== Summary ===\n", .{});
    std.debug.print("MemoryManager cache: {} memories\n", .{mem_manager.memory_content.count()});
    std.debug.print("Graph index: {} total nodes\n", .{memora_db.graph_index.nodes.count()});
    std.debug.print("Missing from graph: {}\n", .{missing_count});
    std.debug.print("Orphaned in graph: {}\n", .{orphaned_count});
    
    std.debug.print("\n=== Test Complete ===\n", .{});
} 