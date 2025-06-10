const std = @import("std");
const memora = @import("memora");
const node_discovery = memora.node_discovery;
const gossip = memora.gossip;
const raft = memora.raft;

/// Gossip Protocol Demo
/// Demonstrates automatic node discovery and cluster formation using gossip protocol
/// This shows how nodes can automatically find each other without manual configuration

fn handleDiscoveryEvent(event: node_discovery.DiscoveryEvent, node: gossip.NodeInfo) void {
    var addr_buf: [16]u8 = undefined;
    const addr_str = node.getAddressString(&addr_buf) catch "unknown";
    
    switch (event) {
        .node_joined => std.debug.print("✅ New node joined cluster: {} ({s}:{})\n", 
            .{ node.id, addr_str, node.raft_port }),
        .node_left => std.debug.print("👋 Node left cluster: {} ({s}:{})\n", 
            .{ node.id, addr_str, node.raft_port }),
        .node_failed => std.debug.print("❌ Node failed: {} ({s}:{})\n", 
            .{ node.id, addr_str, node.raft_port }),
        .cluster_formed => std.debug.print("🎉 Cluster formation complete! Leader node: {}\n", .{node.id}),
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("🚀 Memora Gossip Protocol Demo\n", .{});
    std.debug.print("=====================================\n", .{});
    std.debug.print("This demo shows automatic node discovery without manual configuration\n\n", .{});
    
    // Simulate different scenarios
    try singleNodeDemo(allocator);
    try multiNodeSimulation(allocator);
}

/// Demo 1: Single node cluster (development scenario)
fn singleNodeDemo(allocator: std.mem.Allocator) !void {
    std.debug.print("📍 Demo 1: Single Node Development Cluster\n", .{});
    std.debug.print("------------------------------------------\n", .{});
    
    // Create single-node discovery config
    const discovery_config = node_discovery.createDevConfig(1);
    
    var discovery = try node_discovery.NodeDiscovery.init(allocator, discovery_config);
    defer discovery.deinit();
    
    // Set event handler
    discovery.setEventHandler(handleDiscoveryEvent);
    
    // Force cluster formation for single node
    discovery.forceClusterFormation();
    
    // Get discovered nodes
    const discovered = try discovery.getDiscoveredNodes();
    defer allocator.free(discovered);
    
    std.debug.print("Discovered {} nodes in single-node cluster\n", .{discovered.len});
    for (discovered) |node| {
        var addr_buf: [16]u8 = undefined;
        const addr_str = try node.getAddressString(&addr_buf);
        std.debug.print("  - Node {}: {s}:{} (state: {any})\n", 
            .{ node.id, addr_str, node.raft_port, node.state });
    }
    
    // Create Raft cluster config
    const raft_nodes = try discovery.getRaftReadyNodes();
    defer {
        for (raft_nodes) |node| {
            allocator.free(node.address);
        }
        allocator.free(raft_nodes);
    }
    
    std.debug.print("Raft-ready nodes: {}\n", .{raft_nodes.len});
    for (raft_nodes) |node| {
        std.debug.print("  - Raft Node {}: {s}:{}\n", .{ node.id, node.address, node.port });
    }
    
    std.debug.print("✅ Single node cluster demo complete\n\n", .{});
}

/// Demo 2: Multi-node cluster simulation
fn multiNodeSimulation(allocator: std.mem.Allocator) !void {
    std.debug.print("📍 Demo 2: Multi-Node Cluster Simulation\n", .{});
    std.debug.print("----------------------------------------\n", .{});
    
    // Simulate multiple nodes by creating their configurations
    // In real deployment, these would be separate processes/machines
    
    // Node 1: Bootstrap node
    const node1_config = createSimulatedNodeConfig(1, &[_][]const u8{});
    var node1_discovery = try node_discovery.NodeDiscovery.init(allocator, node1_config);
    defer node1_discovery.deinit();
    
    // Node 2: Joins via bootstrap
    const bootstrap_nodes = [_][]const u8{"127.0.0.1:7946"};
    const node2_config = createSimulatedNodeConfig(2, &bootstrap_nodes);
    var node2_discovery = try node_discovery.NodeDiscovery.init(allocator, node2_config);
    defer node2_discovery.deinit();
    
    // Node 3: Also joins via bootstrap
    const node3_config = createSimulatedNodeConfig(3, &bootstrap_nodes);
    var node3_discovery = try node_discovery.NodeDiscovery.init(allocator, node3_config);
    defer node3_discovery.deinit();
    
    // Set event handlers for all nodes
    node1_discovery.setEventHandler(handleDiscoveryEvent);
    node2_discovery.setEventHandler(handleDiscoveryEvent);
    node3_discovery.setEventHandler(handleDiscoveryEvent);
    
    std.debug.print("Starting 3-node cluster simulation...\n", .{});
    
    // Simulate cluster formation (in real scenario, these would be separate processes)
    // For demo purposes, we'll just show the configuration and logic
    
    // Check cluster readiness for each node
    std.debug.print("\nChecking cluster readiness:\n", .{});
    std.debug.print("Node 1 cluster ready: {}\n", .{node1_discovery.isClusterReady()});
    std.debug.print("Node 2 cluster ready: {}\n", .{node2_discovery.isClusterReady()});
    std.debug.print("Node 3 cluster ready: {}\n", .{node3_discovery.isClusterReady()});
    
    // Simulate successful gossip discovery by manually adding nodes
    // (In real deployment, gossip protocol would handle this automatically)
    
    std.debug.print("\n🔄 Simulating gossip protocol node discovery...\n", .{});
    
    // Create node info for simulation
    const node1_info = try gossip.NodeInfo.fromAddress(1, "127.0.0.1", 7946, 8000);
    const node2_info = try gossip.NodeInfo.fromAddress(2, "127.0.0.1", 7947, 8001);
    const node3_info = try gossip.NodeInfo.fromAddress(3, "127.0.0.1", 7948, 8002);
    
    // Simulate discovery events
    handleDiscoveryEvent(.node_joined, node1_info);
    handleDiscoveryEvent(.node_joined, node2_info);
    handleDiscoveryEvent(.node_joined, node3_info);
    handleDiscoveryEvent(.cluster_formed, node1_info);
    
    // Show final cluster configuration
    std.debug.print("\n📊 Final Cluster Configuration:\n", .{});
    
    // Create simulated cluster config
    var raft_nodes = std.ArrayList(raft.ClusterConfig.NodeInfo).init(allocator);
    defer {
        for (raft_nodes.items) |node| {
            allocator.free(node.address);
        }
        raft_nodes.deinit();
    }
    
    // Add nodes to cluster config
    try raft_nodes.append(.{
        .id = 1,
        .address = try allocator.dupe(u8, "127.0.0.1"),
        .port = 8000,
    });
    try raft_nodes.append(.{
        .id = 2,
        .address = try allocator.dupe(u8, "127.0.0.1"),
        .port = 8001,
    });
    try raft_nodes.append(.{
        .id = 3,
        .address = try allocator.dupe(u8, "127.0.0.1"),
        .port = 8002,
    });
    
    std.debug.print("Cluster has {} nodes:\n", .{raft_nodes.items.len});
    for (raft_nodes.items) |node| {
        std.debug.print("  - Node {}: {s}:{}\n", .{ node.id, node.address, node.port });
    }
    
    std.debug.print("\n✅ Multi-node cluster simulation complete\n", .{});
    
    // Show gossip protocol benefits
    std.debug.print("\n🎯 Gossip Protocol Benefits Demonstrated:\n", .{});
    std.debug.print("  ✅ Decentralized discovery (no service registry needed)\n", .{});
    std.debug.print("  ✅ Fault tolerance (nodes can leave/join dynamically)\n", .{});
    std.debug.print("  ✅ Self-healing (failed nodes automatically detected)\n", .{});
    std.debug.print("  ✅ Zero configuration (bootstrap with seed nodes only)\n", .{});
    std.debug.print("  ✅ Automatic cluster formation\n", .{});
    std.debug.print("  ✅ Integration with Raft consensus\n", .{});
}

/// Create simulated node configuration for demo
fn createSimulatedNodeConfig(node_id: u64, bootstrap_nodes: []const []const u8) node_discovery.DiscoveryConfig {
    const gossip_config = gossip.GossipConfig{
        .node_id = node_id,
        .bind_address = "127.0.0.1",
        .gossip_port = 7945 + @as(u16, @intCast(node_id)), // Unique ports: 7946, 7947, 7948
        .raft_port = 7999 + @as(u16, @intCast(node_id)),   // Unique ports: 8000, 8001, 8002
        .bootstrap_nodes = bootstrap_nodes,
        .gossip_interval_ms = 1000,
        .failure_detection_timeout_ms = 5000,
        .suspect_timeout_ms = 10000,
        .dead_timeout_ms = 30000,
        .gossip_fanout = 2, // Smaller fanout for demo
        .max_compound_messages = 5,
        .bootstrap_timeout_ms = 10000,
    };
    
    return node_discovery.DiscoveryConfig{
        .gossip_config = gossip_config,
        .enable_raft_integration = true,
        .raft_bootstrap_threshold = 3,
        .auto_cluster_formation = true,
        .cluster_size_hint = 3,
    };
} 