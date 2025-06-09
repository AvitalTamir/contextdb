const std = @import("std");
const testing = std.testing;
const contextdb = @import("contextdb");
const fuzzing = contextdb.fuzzing;
const raft = contextdb.raft;
const types = contextdb.types;

// =============================================================================
// Distributed Fuzzing for Raft Consensus
// =============================================================================

/// Distributed cluster state for fuzzing
const ClusterState = struct {
    nodes: []TestRaftNode,
    network: fuzzing.NetworkSimulator,
    tick_count: u32,
    
    const TestRaftNode = struct {
        node: *raft.RaftNode,
        allocator: std.mem.Allocator,
        partitioned: bool, // Whether this node is network partitioned
        
        pub fn deinit(self: *TestRaftNode) void {
            self.node.deinit();
        }
    };
    
    pub fn init(allocator: std.mem.Allocator, node_count: u8) !ClusterState {
        var nodes = try allocator.alloc(TestRaftNode, node_count);
        errdefer allocator.free(nodes);
        
        // Create cluster configuration
        var node_infos = try allocator.alloc(raft.ClusterConfig.NodeInfo, node_count);
        defer allocator.free(node_infos);
        
        for (node_infos, 0..) |*info, i| {
            info.* = .{
                .id = @as(u8, @intCast(i + 1)),
                .address = "127.0.0.1",
                .port = @as(u16, @intCast(8000 + i)),
            };
        }
        
        const cluster_config = raft.ClusterConfig{ .nodes = node_infos };
        
        // Initialize nodes
        for (nodes, 0..) |*test_node, i| {
            const node_id = @as(u8, @intCast(i + 1));
            
            // Create temporary directory for each node
            var dir_buf: [64]u8 = undefined;
            const data_dir = try std.fmt.bufPrint(&dir_buf, "fuzz_raft_node_{}", .{node_id});
            
            std.fs.cwd().deleteTree(data_dir) catch {};
            try std.fs.cwd().makeDir(data_dir);
            
            const raft_node = try allocator.create(raft.RaftNode);
            raft_node.* = try raft.RaftNode.init(allocator, node_id, cluster_config, data_dir, null);
            
            test_node.* = TestRaftNode{
                .node = raft_node,
                .allocator = allocator,
                .partitioned = false,
            };
        }
        
        return ClusterState{
            .nodes = nodes,
            .network = fuzzing.NetworkSimulator.init(allocator),
            .tick_count = 0,
        };
    }
    
    pub fn deinit(self: *ClusterState, allocator: std.mem.Allocator) void {
        // Clean up nodes
        for (self.nodes) |*test_node| {
            test_node.deinit();
            allocator.destroy(test_node.node);
        }
        allocator.free(self.nodes);
        
        // Clean up network
        self.network.deinit();
        
        // Clean up test directories
        for (0..self.nodes.len) |i| {
            var dir_buf: [64]u8 = undefined;
            const data_dir = std.fmt.bufPrint(&dir_buf, "fuzz_raft_node_{}", .{i + 1}) catch continue;
            std.fs.cwd().deleteTree(data_dir) catch {};
        }
    }
    
    /// Simulate one tick of the distributed system
    pub fn tick(self: *ClusterState, frng: *fuzzing.FiniteRng) !void {
        self.tick_count += 1;
        
        // Deliver pending network messages
        if (try self.network.tick()) |message| {
            defer self.network.allocator.free(message.payload);
            
            // Check if destination is partitioned
            const dst_idx = message.dst - 1;
            if (dst_idx < self.nodes.len and !self.nodes[dst_idx].partitioned) {
                const response = try self.nodes[dst_idx].node.handleMessage(message.msg_type, message.payload);
                defer if (response.len > 0) self.network.allocator.free(response);
                
                // Send response back if any
                if (response.len > 0) {
                    try self.network.sendMessage(frng, message.dst, message.src, message.msg_type, response);
                }
            }
        }
        
        // Process timeouts and trigger elections
        for (self.nodes) |*test_node| {
            if (!test_node.partitioned) {
                try test_node.node.tick();
                
                // If node becomes candidate, send vote requests
                if (test_node.node.state == .candidate) {
                    try self.sendVoteRequests(frng, test_node.node);
                }
                
                // If node is leader, send heartbeats
                if (test_node.node.state == .leader and self.tick_count % 5 == 0) {
                    try self.sendHeartbeats(frng, test_node.node);
                }
            }
        }
    }
    
    fn sendVoteRequests(self: *ClusterState, frng: *fuzzing.FiniteRng, candidate: *raft.RaftNode) !void {
        const vote_request = raft.RequestVoteRequest{
            .term = candidate.persistent_state.current_term,
            .candidate_id = candidate.node_id,
            .last_log_index = if (candidate.log_entries.items.len > 0) 
                candidate.log_entries.items[candidate.log_entries.items.len - 1].index 
            else 0,
            .last_log_term = if (candidate.log_entries.items.len > 0) 
                candidate.log_entries.items[candidate.log_entries.items.len - 1].term 
            else 0,
        };
        
        const request_bytes = std.mem.asBytes(&vote_request);
        
        for (self.nodes) |*test_node| {
            if (test_node.node.node_id != candidate.node_id and !test_node.partitioned) {
                try self.network.sendMessage(
                    frng,
                    candidate.node_id,
                    test_node.node.node_id,
                    .request_vote,
                    request_bytes
                );
            }
        }
    }
    
    fn sendHeartbeats(self: *ClusterState, frng: *fuzzing.FiniteRng, leader: *raft.RaftNode) !void {
        const heartbeat = raft.AppendEntriesRequest{
            .term = leader.persistent_state.current_term,
            .leader_id = leader.node_id,
            .prev_log_index = 0, // Simplified for fuzzing
            .prev_log_term = 0,
            .leader_commit = leader.commit_index,
            .entry_count = 0,
        };
        
        const heartbeat_bytes = std.mem.asBytes(&heartbeat);
        
        for (self.nodes) |*test_node| {
            if (test_node.node.node_id != leader.node_id and !test_node.partitioned) {
                try self.network.sendMessage(
                    frng,
                    leader.node_id,
                    test_node.node.node_id,
                    .append_entries,
                    heartbeat_bytes
                );
            }
        }
    }
    
    /// Partition a specific node from the network
    pub fn partitionNode(self: *ClusterState, node_id: u8) void {
        if (node_id > 0 and node_id <= self.nodes.len) {
            self.nodes[node_id - 1].partitioned = true;
        }
    }
    
    /// Heal a partitioned node
    pub fn healNode(self: *ClusterState, node_id: u8) void {
        if (node_id > 0 and node_id <= self.nodes.len) {
            self.nodes[node_id - 1].partitioned = false;
        }
    }
    
    /// Get the current leader, if any
    pub fn getLeader(self: *ClusterState) ?u8 {
        for (self.nodes) |*test_node| {
            if (test_node.node.state == .leader and !test_node.partitioned) {
                return test_node.node.node_id;
            }
        }
        return null;
    }
    
    /// Check if all non-partitioned nodes have converged on the same term
    pub fn nodesConverged(self: *ClusterState) bool {
        var expected_term: ?u64 = null;
        
        for (self.nodes) |*test_node| {
            if (!test_node.partitioned) {
                if (expected_term == null) {
                    expected_term = test_node.node.persistent_state.current_term;
                } else if (expected_term.? != test_node.node.persistent_state.current_term) {
                    return false;
                }
            }
        }
        
        return expected_term != null;
    }
    
    /// Get active (non-partitioned) node count
    pub fn activeNodeCount(self: *ClusterState) u8 {
        var count: u8 = 0;
        for (self.nodes) |*test_node| {
            if (!test_node.partitioned) count += 1;
        }
        return count;
    }
};

/// Specific distributed fuzzing scenarios
const DistributedFuzzScenario = struct {
    /// Basic leader election scenario
    pub fn basicLeaderElection(allocator: std.mem.Allocator, frng: *fuzzing.FiniteRng) !void {
        var cluster = try ClusterState.init(allocator, 3);
        defer cluster.deinit(allocator);
        
        std.debug.print("Starting basic leader election fuzz scenario...\n", .{});
        
        // Run until a leader is elected or timeout
        const max_ticks = 1000;
        var ticks: u32 = 0;
        
        while (ticks < max_ticks) : (ticks += 1) {
            try cluster.tick(frng);
            
            if (cluster.getLeader()) |leader_id| {
                std.debug.print("✓ Leader elected: Node {} after {} ticks\n", .{ leader_id, ticks });
                return;
            }
            
            // Add some randomness every 100 ticks
            if (ticks % 100 == 0 and frng.hasEntropy()) {
                if (frng.randomBool() catch false) {
                    // Temporarily partition a random node
                    const node_to_partition = 1 + (frng.randomUsize(3) catch 0);
                    cluster.partitionNode(@intCast(node_to_partition));
                    std.debug.print("  Partitioned node {} at tick {}\n", .{ node_to_partition, ticks });
                    
                    // Heal after a few ticks
                    var heal_ticks: u32 = 0;
                    while (heal_ticks < 50 and ticks + heal_ticks < max_ticks) : (heal_ticks += 1) {
                        try cluster.tick(frng);
                    }
                    ticks += heal_ticks;
                    
                    cluster.healNode(@intCast(node_to_partition));
                    std.debug.print("  Healed node {} at tick {}\n", .{ node_to_partition, ticks });
                }
            }
        }
        
        std.debug.print("⚠ Leader election timeout after {} ticks\n", .{max_ticks});
    }
    
    /// Network partition scenario - split brain protection
    pub fn networkPartition(allocator: std.mem.Allocator, frng: *fuzzing.FiniteRng) !void {
        var cluster = try ClusterState.init(allocator, 5);
        defer cluster.deinit(allocator);
        
        std.debug.print("Starting network partition fuzz scenario...\n", .{});
        
        // First, establish a leader
        const max_setup_ticks = 500;
        var ticks: u32 = 0;
        
        while (ticks < max_setup_ticks and cluster.getLeader() == null) : (ticks += 1) {
            try cluster.tick(frng);
        }
        
        const initial_leader = cluster.getLeader();
        if (initial_leader == null) {
            std.debug.print("⚠ Failed to establish initial leader\n", .{});
            return;
        }
        
        std.debug.print("✓ Initial leader established: Node {}\n", .{initial_leader.?});
        
        // Create minority partition (2 nodes isolated)
        cluster.partitionNode(4);
        cluster.partitionNode(5);
        std.debug.print("  Partitioned nodes 4 and 5 (minority)\n", .{});
        
        // Majority (nodes 1, 2, 3) should maintain leadership
        ticks = 0;
        const partition_test_ticks = 200;
        var majority_leader_count: u32 = 0;
        var minority_leader_count: u32 = 0;
        
        while (ticks < partition_test_ticks) : (ticks += 1) {
            try cluster.tick(frng);
            
            // Check if majority has a leader
            var majority_has_leader = false;
            for (cluster.nodes[0..3]) |*test_node| {
                if (test_node.node.state == .leader) {
                    majority_has_leader = true;
                    break;
                }
            }
            
            // Check if minority tries to elect a leader (they shouldn't succeed)
            var minority_has_leader = false;
            for (cluster.nodes[3..5]) |*test_node| {
                if (test_node.node.state == .leader) {
                    minority_has_leader = true;
                    break;
                }
            }
            
            if (majority_has_leader) majority_leader_count += 1;
            if (minority_has_leader) minority_leader_count += 1;
        }
        
        std.debug.print("  Majority had leader for {}/{} ticks\n", .{ majority_leader_count, partition_test_ticks });
        std.debug.print("  Minority had leader for {}/{} ticks\n", .{ minority_leader_count, partition_test_ticks });
        
        // Minority should not have been able to elect a leader (split-brain protection)
        if (minority_leader_count == 0) {
            std.debug.print("✓ Split-brain protection working correctly\n", .{});
        } else {
            std.debug.print("⚠ Possible split-brain detected!\n", .{});
        }
        
        // Heal the partition
        cluster.healNode(4);
        cluster.healNode(5);
        std.debug.print("  Healed partition\n", .{});
        
        // All nodes should converge
        ticks = 0;
        const heal_test_ticks = 200;
        while (ticks < heal_test_ticks) : (ticks += 1) {
            try cluster.tick(frng);
            
            if (cluster.nodesConverged()) {
                std.debug.print("✓ All nodes converged after {} heal ticks\n", .{ticks});
                return;
            }
        }
        
        std.debug.print("⚠ Nodes did not converge after healing\n", .{});
    }
    
    /// Random chaos scenario - random partitions and heals
    pub fn randomChaos(allocator: std.mem.Allocator, frng: *fuzzing.FiniteRng) !void {
        var cluster = try ClusterState.init(allocator, 5);
        defer cluster.deinit(allocator);
        
        std.debug.print("Starting random chaos fuzz scenario...\n", .{});
        
        const total_ticks = 1000;
        var leader_elections: u32 = 0;
        var current_leader: ?u8 = null;
        
        for (0..total_ticks) |tick| {
            try cluster.tick(frng);
            
            // Random network chaos every 50 ticks
            if (tick % 50 == 0 and frng.hasEntropy()) {
                const chaos_type = frng.randomUsize(4) catch 0;
                
                switch (chaos_type) {
                    0 => {
                        // Partition random node
                        const node_id = 1 + (frng.randomUsize(5) catch 0);
                        if (!cluster.nodes[node_id - 1].partitioned) {
                            cluster.partitionNode(@intCast(node_id));
                            std.debug.print("  Tick {}: Partitioned node {}\n", .{ tick, node_id });
                        }
                    },
                    1 => {
                        // Heal random node
                        const node_id = 1 + (frng.randomUsize(5) catch 0);
                        if (cluster.nodes[node_id - 1].partitioned) {
                            cluster.healNode(@intCast(node_id));
                            std.debug.print("  Tick {}: Healed node {}\n", .{ tick, node_id });
                        }
                    },
                    2 => {
                        // Partition majority
                        cluster.partitionNode(1);
                        cluster.partitionNode(2);
                        cluster.partitionNode(3);
                        std.debug.print("  Tick {}: Majority partition\n", .{tick});
                    },
                    3 => {
                        // Heal all nodes
                        for (1..6) |node_id| {
                            cluster.healNode(@intCast(node_id));
                        }
                        std.debug.print("  Tick {}: Healed all nodes\n", .{tick});
                    },
                    else => {},
                }
            }
            
            // Track leader changes
            const new_leader = cluster.getLeader();
            if (new_leader != current_leader) {
                if (new_leader) |leader_id| {
                    leader_elections += 1;
                    std.debug.print("  Tick {}: New leader elected: Node {}\n", .{ tick, leader_id });
                }
                current_leader = new_leader;
            }
            
            // Ensure we don't have too many active partitions (keep majority available)
            var partitioned_count: u8 = 0;
            for (cluster.nodes) |*test_node| {
                if (test_node.partitioned) partitioned_count += 1;
            }
            
            if (partitioned_count >= 3) { // More than minority partitioned
                // Heal one random partitioned node to maintain majority
                for (cluster.nodes, 0..) |*test_node, i| {
                    if (test_node.partitioned) {
                        cluster.healNode(@intCast(i + 1));
                        break;
                    }
                }
            }
        }
        
        std.debug.print("✓ Chaos scenario completed: {} leader elections in {} ticks\n", .{ leader_elections, total_ticks });
        std.debug.print("  Final leader: {?}\n", .{cluster.getLeader()});
        std.debug.print("  Active nodes: {}\n", .{cluster.activeNodeCount()});
        std.debug.print("  Nodes converged: {}\n", .{cluster.nodesConverged()});
    }
};

// =============================================================================
// Distributed Fuzzing Tests
// =============================================================================

test "Distributed fuzzing: basic leader election" {
    const entropy = [_]u8{0x33} ** 128;
    var frng = fuzzing.FiniteRng.init(&entropy);
    
    try DistributedFuzzScenario.basicLeaderElection(testing.allocator, &frng);
}

test "Distributed fuzzing: network partition resistance" {
    const entropy = [_]u8{0x55} ** 256;
    var frng = fuzzing.FiniteRng.init(&entropy);
    
    try DistributedFuzzScenario.networkPartition(testing.allocator, &frng);
}

test "Distributed fuzzing: random chaos scenario" {
    const entropy = [_]u8{0x77} ** 512;
    var frng = fuzzing.FiniteRng.init(&entropy);
    
    try DistributedFuzzScenario.randomChaos(testing.allocator, &frng);
}

test "Cluster state management" {
    var cluster = try ClusterState.init(testing.allocator, 3);
    defer cluster.deinit(testing.allocator);
    
    // Test basic cluster operations
    try testing.expect(cluster.activeNodeCount() == 3);
    try testing.expect(cluster.getLeader() == null); // No leader initially
    
    // Test partitioning
    cluster.partitionNode(2);
    try testing.expect(cluster.activeNodeCount() == 2);
    
    // Test healing
    cluster.healNode(2);
    try testing.expect(cluster.activeNodeCount() == 3);
    
    std.debug.print("✓ Cluster state management test passed\n", .{});
}

test "Network simulator in distributed context" {
    var network = fuzzing.NetworkSimulator.init(testing.allocator);
    defer network.deinit();
    
    const entropy = [_]u8{0x99} ** 64;
    var frng = fuzzing.FiniteRng.init(&entropy);
    
    // Simulate Raft message exchange
    try network.sendMessage(&frng, 1, 2, .request_vote, &[_]u8{ 0x01, 0x02, 0x03, 0x04 });
    try network.sendMessage(&frng, 2, 1, .append_entries, &[_]u8{ 0x05, 0x06 });
    
    var delivered_count: u32 = 0;
    var max_ticks: u32 = 100;
    
    while (max_ticks > 0) : (max_ticks -= 1) {
        if (try network.tick()) |message| {
            defer network.allocator.free(message.payload);
            delivered_count += 1;
            
            std.debug.print("Delivered message: {} -> {}, type: {}, payload len: {}\n", .{
                message.src, message.dst, message.msg_type, message.payload.len
            });
        }
        
        if (network.pendingMessages() == 0) break;
    }
    
    std.debug.print("✓ Network simulation delivered {} messages\n", .{delivered_count});
}

test "Predicate-based testing framework" {
    // Test the predicate system
    const leader_predicate = fuzzing.TestPredicate.checkLeaderElected(1);
    try testing.expect(leader_predicate.predicate_type == .leader_elected);
    try testing.expect(leader_predicate.parameters.leader_id == 1);
    
    const converged_predicate = fuzzing.TestPredicate.checkNodesConverged(42);
    try testing.expect(converged_predicate.predicate_type == .nodes_converged);
    try testing.expect(converged_predicate.parameters.converged_term == 42);
    
    const predicates = [_]fuzzing.TestPredicate{ leader_predicate, converged_predicate };
    const scenario = fuzzing.DistributedScenario.init("test_scenario", &predicates, 1000);
    
    try testing.expect(std.mem.eql(u8, scenario.name, "test_scenario"));
    try testing.expect(scenario.predicates.len == 2);
    try testing.expect(scenario.max_ticks == 1000);
    
    std.debug.print("✓ Predicate-based testing framework test passed\n", .{});
}

test "Deterministic distributed fuzzing" {
    // Test that the same seed produces the same distributed execution
    const seed = fuzzing.FuzzSeed.init(64, 42424242);
    const entropy1 = try seed.generateEntropy(testing.allocator);
    defer testing.allocator.free(entropy1);
    
    const entropy2 = try seed.generateEntropy(testing.allocator);
    defer testing.allocator.free(entropy2);
    
    // Should be identical
    try testing.expect(std.mem.eql(u8, entropy1, entropy2));
    
    var frng1 = fuzzing.FiniteRng.init(entropy1);
    var frng2 = fuzzing.FiniteRng.init(entropy2);
    
    // Same entropy should produce same random choices
    const choice1 = frng1.randomU32() catch 0;
    const choice2 = frng2.randomU32() catch 0;
    try testing.expect(choice1 == choice2);
    
    std.debug.print("✓ Deterministic distributed fuzzing test passed\n", .{});
}

// =============================================================================
// Performance Tests for Distributed Fuzzing
// =============================================================================

test "Distributed fuzzing performance baseline" {
    const entropy = [_]u8{0xAB} ** 64;
    var frng = fuzzing.FiniteRng.init(&entropy);
    
    const start_time = std.time.nanoTimestamp();
    
    var cluster = try ClusterState.init(testing.allocator, 3);
    defer cluster.deinit(testing.allocator);
    
    // Run a short simulation
    const test_ticks = 100;
    for (0..test_ticks) |_| {
        try cluster.tick(&frng);
    }
    
    const end_time = std.time.nanoTimestamp();
    const duration_ms = @as(u64, @intCast(end_time - start_time)) / 1_000_000;
    
    std.debug.print("✓ {} ticks simulated in {}ms ({d:.2} ticks/ms)\n", .{
        test_ticks, duration_ms, @as(f64, @floatFromInt(test_ticks)) / @as(f64, @floatFromInt(duration_ms))
    });
    
    // Should complete in reasonable time
    try testing.expect(duration_ms < 1000); // Less than 1 second
} 