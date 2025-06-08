const std = @import("std");
const testing = std.testing;
const contextdb = @import("contextdb");

// Comprehensive Raft Consensus Tests
// Following TigerBeetle-style testing: deterministic, extensive, zero external dependencies

test "Raft persistent state save and load" {
    const allocator = testing.allocator;
    
    // Clean up any existing test data
    std.fs.cwd().deleteFile("test_raft_state.bin") catch {};
    defer std.fs.cwd().deleteFile("test_raft_state.bin") catch {};
    
    // Test state
    const original_state = contextdb.raft.PersistentState{
        .current_term = 42,
        .voted_for = 123,
        .log_start_index = 10,
    };
    
    // Save state
    try original_state.save(allocator, "test_raft_state.bin");
    
    // Load state back
    const loaded_state = try contextdb.raft.PersistentState.load(allocator, "test_raft_state.bin");
    
    // Verify state integrity
    try testing.expect(loaded_state.current_term == original_state.current_term);
    try testing.expect(loaded_state.voted_for.? == original_state.voted_for.?);
    try testing.expect(loaded_state.log_start_index == original_state.log_start_index);
}

test "Raft persistent state default values" {
    const allocator = testing.allocator;
    
    // Load non-existent file should return defaults
    const default_state = try contextdb.raft.PersistentState.load(allocator, "non_existent_file.bin");
    
    try testing.expect(default_state.current_term == 0);
    try testing.expect(default_state.voted_for == null);
    try testing.expect(default_state.log_start_index == 0);
}

test "Raft cluster configuration" {
    const node_infos = [_]contextdb.raft.ClusterConfig.NodeInfo{
        .{ .id = 1, .address = "127.0.0.1", .port = 8001 },
        .{ .id = 2, .address = "127.0.0.1", .port = 8002 },
        .{ .id = 3, .address = "127.0.0.1", .port = 8003 },
    };
    
    const config = contextdb.raft.ClusterConfig{
        .nodes = &node_infos,
    };
    
    // Test node lookup
    try testing.expect(config.getNodeIndex(1).? == 0);
    try testing.expect(config.getNodeIndex(2).? == 1);
    try testing.expect(config.getNodeIndex(3).? == 2);
    try testing.expect(config.getNodeIndex(999) == null);
    
    // Test majority calculation
    try testing.expect(config.getMajority() == 2); // (3/2) + 1 = 2
}

test "Raft node initialization" {
    const allocator = testing.allocator;
    
    // Clean up test data
    std.fs.cwd().deleteTree("test_raft_node") catch {};
    defer std.fs.cwd().deleteTree("test_raft_node") catch {};
    
    try std.fs.cwd().makeDir("test_raft_node");
    
    const node_infos = [_]contextdb.raft.ClusterConfig.NodeInfo{
        .{ .id = 1, .address = "127.0.0.1", .port = 8001 },
        .{ .id = 2, .address = "127.0.0.1", .port = 8002 },
    };
    
    const cluster_config = contextdb.raft.ClusterConfig{ .nodes = &node_infos };
    
    var raft_node = try contextdb.raft.RaftNode.init(allocator, 1, cluster_config, "test_raft_node");
    defer raft_node.deinit();
    
    // Test initial state
    try testing.expect(raft_node.node_id == 1);
    try testing.expect(raft_node.state == .follower);
    try testing.expect(raft_node.persistent_state.current_term == 0);
    try testing.expect(raft_node.persistent_state.voted_for == null);
    try testing.expect(raft_node.log_entries.items.len == 0);
}

test "Raft log entry serialization" {
    const entry = contextdb.raft.LogEntry{
        .term = 5,
        .index = 10,
        .entry_type = .contextdb_operation,
        .data_size = 100,
        .checksum = 0x12345678,
    };
    
    // Test packed struct size consistency
    const expected_size = @sizeOf(contextdb.raft.LogEntry);
    std.debug.print("LogEntry size: {} bytes\n", .{expected_size});
    try testing.expect(expected_size >= 20); // Should be at least 20 bytes for the fields
    
    // Test serialization
    const entry_bytes = std.mem.asBytes(&entry);
    try testing.expect(entry_bytes.len == @sizeOf(contextdb.raft.LogEntry));
    
    // Test deserialization
    const deserialized = @as(*const contextdb.raft.LogEntry, @ptrCast(@alignCast(entry_bytes.ptr))).*;
    try testing.expect(deserialized.term == entry.term);
    try testing.expect(deserialized.index == entry.index);
    try testing.expect(deserialized.entry_type == entry.entry_type);
    try testing.expect(deserialized.data_size == entry.data_size);
    try testing.expect(deserialized.checksum == entry.checksum);
}

test "Raft request vote handling" {
    const allocator = testing.allocator;
    
    std.fs.cwd().deleteTree("test_vote_handling") catch {};
    defer std.fs.cwd().deleteTree("test_vote_handling") catch {};
    
    try std.fs.cwd().makeDir("test_vote_handling");
    
    const node_infos = [_]contextdb.raft.ClusterConfig.NodeInfo{
        .{ .id = 1, .address = "127.0.0.1", .port = 8001 },
        .{ .id = 2, .address = "127.0.0.1", .port = 8002 },
    };
    
    const cluster_config = contextdb.raft.ClusterConfig{ .nodes = &node_infos };
    
    var raft_node = try contextdb.raft.RaftNode.init(allocator, 1, cluster_config, "test_vote_handling");
    defer raft_node.deinit();
    
    // Create vote request
    const vote_request = contextdb.raft.RequestVoteRequest{
        .term = 1,
        .candidate_id = 2,
        .last_log_index = 0,
        .last_log_term = 0,
    };
    
    const request_bytes = std.mem.asBytes(&vote_request);
    
    // Handle vote request
    const response_bytes = try raft_node.handleMessage(.request_vote, request_bytes);
    defer allocator.free(response_bytes);
    
    // Parse response
    try testing.expect(response_bytes.len == @sizeOf(contextdb.raft.RequestVoteReply));
    const reply = @as(*const contextdb.raft.RequestVoteReply, @ptrCast(@alignCast(response_bytes.ptr))).*;
    
    // Should grant vote for valid candidate in higher term
    try testing.expect(reply.vote_granted == true);
    try testing.expect(reply.term == 1);
    try testing.expect(raft_node.persistent_state.current_term == 1);
    try testing.expect(raft_node.persistent_state.voted_for.? == 2);
}

test "Raft append entries handling" {
    const allocator = testing.allocator;
    
    std.fs.cwd().deleteTree("test_append_handling") catch {};
    defer std.fs.cwd().deleteTree("test_append_handling") catch {};
    
    try std.fs.cwd().makeDir("test_append_handling");
    
    const node_infos = [_]contextdb.raft.ClusterConfig.NodeInfo{
        .{ .id = 1, .address = "127.0.0.1", .port = 8001 },
        .{ .id = 2, .address = "127.0.0.1", .port = 8002 },
    };
    
    const cluster_config = contextdb.raft.ClusterConfig{ .nodes = &node_infos };
    
    var raft_node = try contextdb.raft.RaftNode.init(allocator, 1, cluster_config, "test_append_handling");
    defer raft_node.deinit();
    
    // Create append entries request (heartbeat)
    const append_request = contextdb.raft.AppendEntriesRequest{
        .term = 1,
        .leader_id = 2,
        .prev_log_index = 0,
        .prev_log_term = 0,
        .leader_commit = 0,
        .entry_count = 0,
    };
    
    const request_bytes = std.mem.asBytes(&append_request);
    
    // Handle append entries
    const response_bytes = try raft_node.handleMessage(.append_entries, request_bytes);
    defer allocator.free(response_bytes);
    
    // Parse response
    try testing.expect(response_bytes.len == @sizeOf(contextdb.raft.AppendEntriesReply));
    const reply = @as(*const contextdb.raft.AppendEntriesReply, @ptrCast(@alignCast(response_bytes.ptr))).*;
    
    // Should accept valid heartbeat
    try testing.expect(reply.success == true);
    try testing.expect(reply.term == 1);
    try testing.expect(raft_node.persistent_state.current_term == 1);
    try testing.expect(raft_node.state == .follower);
}

test "Raft network message header" {
    const header = contextdb.raft_network.MessageHeader{
        .message_type = .request_vote,
        .body_size = 100,
        .checksum = 0x12345678,
    };
    
    // Test header size and magic
    try testing.expect(header.magic == 0x52414654); // "RAFT"
    try testing.expect(header.version == 1);
    try testing.expect(@sizeOf(contextdb.raft_network.MessageHeader) >= 16); // Minimum expected size
    
    // Test serialization
    const header_bytes = std.mem.asBytes(&header);
    const deserialized = @as(*const contextdb.raft_network.MessageHeader, @ptrCast(@alignCast(header_bytes.ptr))).*;
    
    try testing.expect(deserialized.magic == header.magic);
    try testing.expect(deserialized.version == header.version);
    try testing.expect(deserialized.message_type == header.message_type);
    try testing.expect(deserialized.body_size == header.body_size);
    try testing.expect(deserialized.checksum == header.checksum);
}

test "Distributed ContextDB configuration" {
    const cluster_nodes = [_]contextdb.distributed_contextdb.DistributedConfig.ClusterNode{
        .{ .id = 1, .address = "127.0.0.1", .raft_port = 8001 },
        .{ .id = 2, .address = "127.0.0.1", .raft_port = 8002 },
        .{ .id = 3, .address = "127.0.0.1", .raft_port = 8003 },
    };
    
    const config = contextdb.distributed_contextdb.DistributedConfig{
        .contextdb_config = .{
            .data_path = "test_distributed_config",
            .enable_persistent_indexes = true,
        },
        .node_id = 1,
        .raft_port = 8001,
        .cluster_nodes = &cluster_nodes,
        .replication_factor = 3,
        .read_quorum = 2,
        .write_quorum = 2,
    };
    
    // Test configuration values
    try testing.expect(config.node_id == 1);
    try testing.expect(config.raft_port == 8001);
    try testing.expect(config.cluster_nodes.len == 3);
    try testing.expect(config.replication_factor == 3);
    try testing.expect(config.read_quorum == 2);
    try testing.expect(config.write_quorum == 2);
    
    // Test cluster node properties
    try testing.expect(config.cluster_nodes[0].id == 1);
    try testing.expect(std.mem.eql(u8, config.cluster_nodes[0].address, "127.0.0.1"));
    try testing.expect(config.cluster_nodes[0].raft_port == 8001);
}

test "State machine operation serialization" {
    const operation = contextdb.distributed_contextdb.StateMachineOperation{
        .operation_type = .insert_node,
        .data_size = 100,
        .checksum = 0x87654321,
    };
    
    // Test packed struct consistency
    try testing.expect(@sizeOf(contextdb.distributed_contextdb.StateMachineOperation) >= 9); // Minimum expected size
    
    // Test serialization roundtrip
    const operation_bytes = std.mem.asBytes(&operation);
    const deserialized = @as(*const contextdb.distributed_contextdb.StateMachineOperation, @ptrCast(@alignCast(operation_bytes.ptr))).*;
    
    try testing.expect(deserialized.operation_type == operation.operation_type);
    try testing.expect(deserialized.data_size == operation.data_size);
    try testing.expect(deserialized.checksum == operation.checksum);
}

test "Raft log consistency checks" {
    const allocator = testing.allocator;
    
    std.fs.cwd().deleteTree("test_log_consistency") catch {};
    defer std.fs.cwd().deleteTree("test_log_consistency") catch {};
    
    try std.fs.cwd().makeDir("test_log_consistency");
    
    const node_infos = [_]contextdb.raft.ClusterConfig.NodeInfo{
        .{ .id = 1, .address = "127.0.0.1", .port = 8001 },
    };
    
    const cluster_config = contextdb.raft.ClusterConfig{ .nodes = &node_infos };
    
    var raft_node = try contextdb.raft.RaftNode.init(allocator, 1, cluster_config, "test_log_consistency");
    defer raft_node.deinit();
    
    // Add some log entries
    const entry1 = contextdb.raft.LogEntry{
        .term = 1,
        .index = 1,
        .entry_type = .contextdb_operation,
        .data_size = 10,
        .checksum = 0x1111,
    };
    
    const entry2 = contextdb.raft.LogEntry{
        .term = 1,
        .index = 2,
        .entry_type = .contextdb_operation,
        .data_size = 20,
        .checksum = 0x2222,
    };
    
    try raft_node.log_entries.append(entry1);
    try raft_node.log_entries.append(entry2);
    
    // Test log index/term retrieval
    try testing.expect(raft_node.getLastLogIndex() == 2);
    try testing.expect(raft_node.getLastLogTerm() == 1);
    
    // Test log up-to-date checks
    try testing.expect(raft_node.isLogUpToDate(2, 1) == true);  // Same as current
    try testing.expect(raft_node.isLogUpToDate(3, 1) == true);  // Longer with same term
    try testing.expect(raft_node.isLogUpToDate(1, 2) == true);  // Higher term
    try testing.expect(raft_node.isLogUpToDate(1, 1) == false); // Shorter with same term
    try testing.expect(raft_node.isLogUpToDate(2, 0) == false); // Lower term
    
    // Test log consistency checks
    try testing.expect(raft_node.checkLogConsistency(0, 0) == true);  // Empty log case
    try testing.expect(raft_node.checkLogConsistency(1, 1) == true);  // Valid entry
    try testing.expect(raft_node.checkLogConsistency(2, 1) == true);  // Valid entry
    try testing.expect(raft_node.checkLogConsistency(1, 2) == false); // Wrong term
    try testing.expect(raft_node.checkLogConsistency(3, 1) == false); // Beyond log
}

test "Raft election timeout and randomization" {
    const allocator = testing.allocator;
    
    std.fs.cwd().deleteTree("test_election_timeout") catch {};
    defer std.fs.cwd().deleteTree("test_election_timeout") catch {};
    
    try std.fs.cwd().makeDir("test_election_timeout");
    
    const node_infos = [_]contextdb.raft.ClusterConfig.NodeInfo{
        .{ .id = 1, .address = "127.0.0.1", .port = 8001 },
    };
    
    const cluster_config = contextdb.raft.ClusterConfig{ .nodes = &node_infos };
    
    var raft_node = try contextdb.raft.RaftNode.init(allocator, 1, cluster_config, "test_election_timeout");
    defer raft_node.deinit();
    
    // Test initial timeout settings
    try testing.expect(raft_node.election_timeout_ms == 150);
    try testing.expect(raft_node.heartbeat_interval_ms == 50);
    
    // Test timeout reset (should set future deadline)
    const before_reset = std.time.milliTimestamp();
    raft_node.resetElectionTimeout();
    try testing.expect(raft_node.election_deadline > @as(u64, @intCast(before_reset)));
    try testing.expect(raft_node.election_deadline >= @as(u64, @intCast(before_reset)) + raft_node.election_timeout_ms);
    try testing.expect(raft_node.election_deadline <= @as(u64, @intCast(before_reset)) + raft_node.election_timeout_ms + 150); // Max random offset
}

test "Raft performance with large cluster" {
    const allocator = testing.allocator;
    
    // Create a larger cluster configuration for performance testing
    const cluster_size = 7; // Odd number for clear majority
    var node_infos = try allocator.alloc(contextdb.raft.ClusterConfig.NodeInfo, cluster_size);
    defer allocator.free(node_infos);
    
    for (0..cluster_size) |i| {
        const address = try allocator.dupe(u8, "127.0.0.1");
        defer allocator.free(address);
        
        node_infos[i] = contextdb.raft.ClusterConfig.NodeInfo{
            .id = @intCast(i + 1),
            .address = address,
            .port = @intCast(8000 + i + 1),
        };
    }
    
    const cluster_config = contextdb.raft.ClusterConfig{ .nodes = node_infos };
    
    // Test majority calculation
    try testing.expect(cluster_config.getMajority() == 4); // (7/2) + 1 = 4
    
    // Test node lookup performance
    const start_time = std.time.nanoTimestamp();
    for (0..1000) |_| {
        _ = cluster_config.getNodeIndex(3);
        _ = cluster_config.getNodeIndex(5);
        _ = cluster_config.getNodeIndex(999); // Non-existent
    }
    const end_time = std.time.nanoTimestamp();
    
    const lookup_time_ns = end_time - start_time;
    try testing.expect(lookup_time_ns < 1_000_000); // Should be under 1ms for 3000 lookups
    
    std.debug.print("Cluster lookup performance: {}ns for 3000 operations\n", .{lookup_time_ns});
}

test "Raft message type completeness" {
    // Ensure all message types are handled
    const message_types = [_]contextdb.raft.MessageType{
        .request_vote,
        .request_vote_reply,
        .append_entries,
        .append_entries_reply,
        .install_snapshot,
        .install_snapshot_reply,
    };
    
    // Test enum values
    try testing.expect(@intFromEnum(contextdb.raft.MessageType.request_vote) == 1);
    try testing.expect(@intFromEnum(contextdb.raft.MessageType.request_vote_reply) == 2);
    try testing.expect(@intFromEnum(contextdb.raft.MessageType.append_entries) == 3);
    try testing.expect(@intFromEnum(contextdb.raft.MessageType.append_entries_reply) == 4);
    try testing.expect(@intFromEnum(contextdb.raft.MessageType.install_snapshot) == 5);
    try testing.expect(@intFromEnum(contextdb.raft.MessageType.install_snapshot_reply) == 6);
    
    // Ensure we have all expected message types
    try testing.expect(message_types.len == 6);
}

test "Checksum calculation consistency" {
    const test_data1 = "Hello, Raft!";
    const test_data2 = "Different data";
    const test_data3 = "Hello, Raft!"; // Same as data1
    
    // Calculate checksums using the same function as the implementation
    const Crc32 = std.hash.Crc32;
    const checksum1 = Crc32.hash(test_data1);
    const checksum2 = Crc32.hash(test_data2);
    const checksum3 = Crc32.hash(test_data3);
    
    // Same data should produce same checksum
    try testing.expect(checksum1 == checksum3);
    
    // Different data should produce different checksums (very high probability)
    try testing.expect(checksum1 != checksum2);
    
    // Checksums should be deterministic
    try testing.expect(Crc32.hash(test_data1) == checksum1);
} 