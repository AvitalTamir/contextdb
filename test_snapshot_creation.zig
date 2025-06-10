const std = @import("std");
const memora = @import("src/main.zig");
const types = @import("src/types.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🧠 Testing Snapshot Creation\n", .{});
    std.debug.print("============================\n\n", .{});

    // Initialize Memora with the existing MCP data
    const config = memora.MemoraConfig{
        .data_path = "memora_mcp_data",
        .enable_persistent_indexes = true,
        .auto_snapshot_interval = null,
        .s3_bucket = null,
        .s3_region = null,
        .s3_prefix = null,
    };

    var db = try memora.Memora.init(allocator, config, null);
    defer db.deinit();

    std.debug.print("📊 Current Database Statistics:\n", .{});
    const stats = db.getStats();
    std.debug.print("  • Nodes: {}\n", .{stats.node_count});
    std.debug.print("  • Edges: {}\n", .{stats.edge_count});
    std.debug.print("  • Vectors: {}\n", .{stats.vector_count});

    std.debug.print("\n📸 Creating manual snapshot...\n", .{});
    
    // Create a manual snapshot
    var snapshot_info = try db.createSnapshot();
    defer snapshot_info.deinit();
    
    std.debug.print("✅ Snapshot created successfully!\n", .{});
    std.debug.print("  • Snapshot ID: {}\n", .{snapshot_info.snapshot_id});
    std.debug.print("  • Node files: {}\n", .{snapshot_info.node_files.len});
    std.debug.print("  • Edge files: {}\n", .{snapshot_info.edge_files.len});
    std.debug.print("  • Vector files: {}\n", .{snapshot_info.vector_files.len});
    
    std.debug.print("\n🗂️ Files should now exist in:\n", .{});
    std.debug.print("  • memora_mcp_data/metadata/snapshot-{:06}.json\n", .{snapshot_info.snapshot_id});
    std.debug.print("  • memora_mcp_data/nodes/node-{:06}.json\n", .{snapshot_info.snapshot_id});
    std.debug.print("  • memora_mcp_data/edges/edge-{:06}.json\n", .{snapshot_info.snapshot_id});
    std.debug.print("  • memora_mcp_data/vectors/vec-{:06}.blob\n", .{snapshot_info.snapshot_id});
    
    std.debug.print("\n🎉 Snapshot creation test complete!\n", .{});
} 