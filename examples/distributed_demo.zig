const std = @import("std");
const memora = @import("memora");

/// Distributed Memora Demo
/// Shows how to set up and use a distributed cluster with Raft consensus

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== DistributedMemora Demo ===\n\n", .{});

    // Clean up any existing demo data
    cleanupDemoData();

    // Demo 1: Single Node Setup
    try demoSingleNodeSetup(allocator);

    // Demo 2: Cluster Configuration
    try demoClusterConfiguration();

    // Demo 3: Distributed Operations
    try demoDistributedOperations();

    // Demo 4: Raft Protocol Basics
    try demoRaftProtocol();

    std.debug.print("\n=== Demo Complete ===\n", .{});
    std.debug.print("To run a full cluster:\n", .{});
    std.debug.print("1. Start each node in a separate terminal\n", .{});
    std.debug.print("2. Use different node IDs (1, 2, 3, etc.)\n", .{});
    std.debug.print("3. Configure same cluster nodes for all instances\n", .{});
    std.debug.print("4. Wait for leader election to complete\n", .{});
    std.debug.print("5. Submit operations to the leader node\n", .{});
}

fn demoSingleNodeSetup(allocator: std.mem.Allocator) !void {
    std.debug.print("Demo 1: Single Node Distributed Memora Setup\n", .{});
    std.debug.print("----------------------------------------------\n", .{});

    // Create single node "cluster"
    const cluster_nodes = [_]memora.distributed_memora.DistributedConfig.ClusterNode{
        .{ .id = 1, .address = "127.0.0.1", .raft_port = 8001 },
    };

    const config = memora.distributed_memora.DistributedConfig{
        .memora_config = memora.MemoraConfig{
            .data_path = "demo_single_node",
            .enable_persistent_indexes = true,
        },
        .node_id = 1,
        .raft_port = 8001,
        .cluster_nodes = &cluster_nodes,
        .replication_factor = 1,
        .read_quorum = 1,
        .write_quorum = 1,
    };

    // Initialize single-node distributed database
    var distributed_db = try memora.distributed_memora.DistributedMemora.init(allocator, config);
    defer distributed_db.deinit();

    // Show cluster status
    const status = distributed_db.getClusterStatus();
    std.debug.print("  Node ID: {}\n", .{status.node_id});
    std.debug.print("  Is Leader: {} (will become leader immediately in single-node cluster)\n", .{status.is_leader});
    std.debug.print("  Operations Count: {}\n", .{status.operation_count});

    std.debug.print("  ✓ Single node cluster configured\n\n", .{});
}

fn demoClusterConfiguration() !void {
    std.debug.print("Demo 2: Multi-Node Cluster Configuration\n", .{});
    std.debug.print("---------------------------------------\n", .{});

    // Create 3-node cluster configuration
    const cluster_nodes = [_]memora.distributed_memora.DistributedConfig.ClusterNode{
        .{ .id = 1, .address = "127.0.0.1", .raft_port = 8001, .memora_port = 9001 },
        .{ .id = 2, .address = "127.0.0.1", .raft_port = 8002, .memora_port = 9002 },
        .{ .id = 3, .address = "127.0.0.1", .raft_port = 8003, .memora_port = 9003 },
    };

    // Configuration for node 1
    const config = memora.distributed_memora.DistributedConfig{
        .memora_config = memora.MemoraConfig{
            .data_path = "demo_cluster_node1",
            .enable_persistent_indexes = true,
        },
        .node_id = 1,
        .raft_port = 8001,
        .cluster_nodes = &cluster_nodes,
        .replication_factor = 3,
        .read_quorum = 2,  // Majority
        .write_quorum = 2, // Majority
    };

    std.debug.print("  Cluster Configuration:\n", .{});
    for (cluster_nodes, 0..) |node, i| {
        std.debug.print("    Node {}: {s}:{} (Memora: {})\n", .{
            node.id,
            node.address,
            node.raft_port,
            node.memora_port orelse 0,
        });
        if (i == 0) std.debug.print("      ^ This node (current process)\n", .{});
    }

    std.debug.print("  Replication Factor: {}\n", .{config.replication_factor});
    std.debug.print("  Read Quorum: {} nodes\n", .{config.read_quorum});
    std.debug.print("  Write Quorum: {} nodes\n", .{config.write_quorum});

    // Note: In production, you'd actually start this node and let it join the cluster
    std.debug.print("  ✓ Cluster configuration prepared\n", .{});
    std.debug.print("    (To fully activate: start each node in separate processes)\n\n", .{});
}

fn demoDistributedOperations() !void {
    std.debug.print("Demo 3: Distributed Operations API\n", .{});
    std.debug.print("---------------------------------\n", .{});

    std.debug.print("  Distributed Memora Operations:\n", .{});
    std.debug.print("  \n", .{});
    std.debug.print("  // Write operations (require consensus)\n", .{});
    std.debug.print("  await distributedDB.insertNode(node);     // Replicated to all nodes\n", .{});
    std.debug.print("  await distributedDB.insertEdge(edge);     // Replicated to all nodes\n", .{});
    std.debug.print("  await distributedDB.insertVector(vector); // Replicated to all nodes\n", .{});
    std.debug.print("  \n", .{});
    std.debug.print("  // Batch operations (single consensus round)\n", .{});
    std.debug.print("  await distributedDB.insertBatch(nodes, edges, vectors);\n", .{});
    std.debug.print("  \n", .{});
    std.debug.print("  // Read operations (can use any up-to-date node)\n", .{});
    std.debug.print("  const similar = await distributedDB.querySimilar(vectorId, topK);\n", .{});
    std.debug.print("  const related = await distributedDB.queryRelated(nodeId, depth);\n", .{});
    std.debug.print("  \n", .{});

    std.debug.print("  State Machine Operations:\n", .{});
    const operation_types = [_][]const u8{
        "insert_node",
        "insert_edge", 
        "insert_vector",
        "batch_insert",
        "create_snapshot",
    };

    for (operation_types) |op_type| {
        std.debug.print("    - {s}\n", .{op_type});
    }

    std.debug.print("  ✓ All operations go through Raft consensus for consistency\n\n", .{});
}

fn demoRaftProtocol() !void {
    std.debug.print("Demo 4: Raft Consensus Protocol Details\n", .{});
    std.debug.print("--------------------------------------\n", .{});

    // Create a Raft cluster configuration
    const cluster_nodes = [_]memora.raft.ClusterConfig.NodeInfo{
        .{ .id = 1, .address = "127.0.0.1", .port = 8001 },
        .{ .id = 2, .address = "127.0.0.1", .port = 8002 },
        .{ .id = 3, .address = "127.0.0.1", .port = 8003 },
    };

    const cluster_config = memora.raft.ClusterConfig{
        .nodes = &cluster_nodes,
    };

    std.debug.print("  Raft Cluster Configuration:\n", .{});
    std.debug.print("    Cluster Size: {}\n", .{cluster_config.nodes.len});
    std.debug.print("    Majority Required: {}\n", .{cluster_config.getMajority()});

    std.debug.print("  \n", .{});
    std.debug.print("  Raft Protocol Components:\n", .{});
    std.debug.print("    ✓ Leader Election\n", .{});
    std.debug.print("      - Election timeout: 150-300ms (randomized)\n", .{});
    std.debug.print("      - Heartbeat interval: 50ms\n", .{});
    std.debug.print("      - Majority voting required\n", .{});
    std.debug.print("    \n", .{});
    std.debug.print("    ✓ Log Replication\n", .{});
    std.debug.print("      - Append Entries RPC\n", .{});
    std.debug.print("      - Consistency checks\n", .{});
    std.debug.print("      - Automatic retry on failure\n", .{});
    std.debug.print("    \n", .{});
    std.debug.print("    ✓ Safety Guarantees\n", .{});
    std.debug.print("      - Election safety\n", .{});
    std.debug.print("      - Leader append-only\n", .{});
    std.debug.print("      - Log matching\n", .{});
    std.debug.print("      - Leader completeness\n", .{});
    std.debug.print("      - State machine safety\n", .{});

    // Show message types
    std.debug.print("  \n", .{});
    std.debug.print("  Raft Message Types:\n", .{});
    const message_types = [_]memora.raft.MessageType{
        .request_vote,
        .request_vote_reply,
        .append_entries,
        .append_entries_reply,
        .install_snapshot,
        .install_snapshot_reply,
    };

    for (message_types) |msg_type| {
        std.debug.print("    - {s}\n", .{@tagName(msg_type)});
    }

    std.debug.print("  \n", .{});
    std.debug.print("  Network Protocol:\n", .{});
    std.debug.print("    - TCP connections between nodes\n", .{});
    std.debug.print("    - Binary message format with CRC32 checksums\n", .{});
    std.debug.print("    - Connection pooling and automatic retry\n", .{});
    std.debug.print("    - 30-second connection timeout\n", .{});

    std.debug.print("  ✓ Raft protocol implementation complete\n\n", .{});
}

fn cleanupDemoData() void {
    const directories = [_][]const u8{
        "demo_single_node",
        "demo_cluster_node1",
        "demo_operations",
    };

    for (directories) |dir| {
        std.fs.cwd().deleteTree(dir) catch {};
    }
} 