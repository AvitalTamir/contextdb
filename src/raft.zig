const std = @import("std");

/// Raft Consensus Implementation for ContextDB
/// Following the Raft paper: "In Search of an Understandable Consensus Algorithm"
/// Designed for TigerBeetle-style deterministic operation

/// Raft node states
pub const NodeState = enum {
    follower,
    candidate, 
    leader,
};

/// Raft RPC message types
pub const MessageType = enum(u8) {
    request_vote = 1,
    request_vote_reply = 2,
    append_entries = 3,
    append_entries_reply = 4,
    install_snapshot = 5,
    install_snapshot_reply = 6,
};

/// Raft log entry
pub const LogEntry = packed struct {
    term: u64,
    index: u64,
    entry_type: EntryType,
    data_size: u32,
    checksum: u32,
    // data follows after this header
    
    pub const EntryType = enum(u8) {
        contextdb_operation = 1,
        configuration_change = 2,
        no_op = 3,
    };
};

/// Request Vote RPC
pub const RequestVoteRequest = packed struct {
    term: u64,
    candidate_id: u64,
    last_log_index: u64,
    last_log_term: u64,
};

pub const RequestVoteReply = packed struct {
    term: u64,
    vote_granted: bool,
};

/// Append Entries RPC  
pub const AppendEntriesRequest = packed struct {
    term: u64,
    leader_id: u64,
    prev_log_index: u64,
    prev_log_term: u64,
    leader_commit: u64,
    entry_count: u32,
    // entries follow after this header
};

pub const AppendEntriesReply = packed struct {
    term: u64,
    success: bool,
    match_index: u64, // For optimization
};

/// Raft persistent state (survives crashes)
pub const PersistentState = struct {
    current_term: u64,
    voted_for: ?u64, // null if haven't voted in current term
    log_start_index: u64, // For compaction
    
    pub fn save(self: *const PersistentState, allocator: std.mem.Allocator, path: []const u8) !void {
        _ = allocator; // Not needed for this implementation
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        
        // Create a buffer with the data
        var buffer: [24]u8 = undefined; // 3 * 8 bytes
        var stream = std.io.fixedBufferStream(&buffer);
        const writer = stream.writer();
        
        // Write term
        try writer.writeInt(u64, self.current_term, .little);
        
        // Write voted_for (use 0xFFFFFFFFFFFFFFFF for null)
        const voted_for_value = self.voted_for orelse 0xFFFFFFFFFFFFFFFF;
        try writer.writeInt(u64, voted_for_value, .little);
        
        // Write log_start_index
        try writer.writeInt(u64, self.log_start_index, .little);
        
        // Write buffer to file
        try file.writeAll(&buffer);
        try file.sync();
    }
    
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !PersistentState {
        _ = allocator; // Not needed for this implementation
        const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return PersistentState{
                .current_term = 0,
                .voted_for = null,
                .log_start_index = 0,
            },
            else => return err,
        };
        defer file.close();
        
        // Read all data
        var buffer: [24]u8 = undefined;
        _ = try file.readAll(&buffer);
        
        var stream = std.io.fixedBufferStream(&buffer);
        const reader = stream.reader();
        
        const current_term = try reader.readInt(u64, .little);
        const voted_for_value = try reader.readInt(u64, .little);
        const log_start_index = try reader.readInt(u64, .little);
        
        const voted_for = if (voted_for_value == 0xFFFFFFFFFFFFFFFF) null else voted_for_value;
        
        return PersistentState{
            .current_term = current_term,
            .voted_for = voted_for,
            .log_start_index = log_start_index,
        };
    }
};

/// Raft volatile state
pub const VolatileState = struct {
    commit_index: u64 = 0,
    last_applied: u64 = 0,
    
    // Leader state (reset after election)
    next_index: ?[]u64 = null, // For each server
    match_index: ?[]u64 = null, // For each server
};

/// Cluster configuration
pub const ClusterConfig = struct {
    nodes: []const NodeInfo,
    
    pub const NodeInfo = struct {
        id: u64,
        address: []const u8,
        port: u16,
    };
    
    pub fn getNodeIndex(self: *const ClusterConfig, node_id: u64) ?usize {
        for (self.nodes, 0..) |node, i| {
            if (node.id == node_id) return i;
        }
        return null;
    }
    
    pub fn getMajority(self: *const ClusterConfig) usize {
        return (self.nodes.len / 2) + 1;
    }
};

/// Core Raft consensus module
pub const RaftNode = struct {
    allocator: std.mem.Allocator,
    node_id: u64,
    cluster_config: ClusterConfig,
    
    // State
    state: NodeState = .follower,
    persistent_state: PersistentState,
    volatile_state: VolatileState = .{},
    
    // Log storage
    log_entries: std.ArrayList(LogEntry),
    log_data: std.ArrayList(u8), // Separate storage for entry data
    
    // Timing
    election_timeout_ms: u64 = 150, // 150-300ms random
    heartbeat_interval_ms: u64 = 50, // Half of min election timeout
    last_heartbeat: u64 = 0,
    election_deadline: u64 = 0,
    
    // Network (placeholder for now)
    network: ?*NetworkLayer = null,
    
    pub fn init(allocator: std.mem.Allocator, node_id: u64, cluster_config: ClusterConfig, data_path: []const u8) !RaftNode {
        const state_path = try std.fs.path.join(allocator, &[_][]const u8{ data_path, "raft_state.bin" });
        defer allocator.free(state_path);
        
        const persistent = try PersistentState.load(allocator, state_path);
        
        return RaftNode{
            .allocator = allocator,
            .node_id = node_id,
            .cluster_config = cluster_config,
            .persistent_state = persistent,
            .log_entries = std.ArrayList(LogEntry).init(allocator),
            .log_data = std.ArrayList(u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *RaftNode) void {
        self.log_entries.deinit();
        self.log_data.deinit();
        if (self.volatile_state.next_index) |ni| self.allocator.free(ni);
        if (self.volatile_state.match_index) |mi| self.allocator.free(mi);
    }
    
    /// Main Raft tick - call this periodically (every ~10ms)
    pub fn tick(self: *RaftNode) !void {
        const now = std.time.milliTimestamp();
        
        switch (self.state) {
            .follower => try self.tickFollower(now),
            .candidate => try self.tickCandidate(now),
            .leader => try self.tickLeader(now),
        }
    }
    
    /// Handle incoming Raft messages
    pub fn handleMessage(self: *RaftNode, msg_type: MessageType, data: []const u8) ![]u8 {
        switch (msg_type) {
            .request_vote => return try self.handleRequestVote(data),
            .append_entries => return try self.handleAppendEntries(data),
            .install_snapshot => return try self.handleInstallSnapshot(data),
            else => return error.UnexpectedMessage,
        }
    }
    
    /// Submit a new entry to be replicated (only on leader)
    pub fn submitEntry(self: *RaftNode, entry_type: LogEntry.EntryType, data: []const u8) !u64 {
        if (self.state != .leader) return error.NotLeader;
        
        const entry = LogEntry{
            .term = self.persistent_state.current_term,
            .index = self.getLastLogIndex() + 1,
            .entry_type = entry_type,
            .data_size = @intCast(data.len),
            .checksum = calculateChecksum(data),
        };
        
        try self.log_entries.append(entry);
        try self.log_data.appendSlice(data);
        
        // Trigger immediate replication
        try self.replicateToFollowers();
        
        return entry.index;
    }
    
    // Private helper methods
    
    fn tickFollower(self: *RaftNode, now: u64) !void {
        if (now > self.election_deadline) {
            try self.startElection();
        }
    }
    
    fn tickCandidate(self: *RaftNode, now: u64) !void {
        if (now > self.election_deadline) {
            try self.startElection(); // Start new election
        }
    }
    
    fn tickLeader(self: *RaftNode, now: u64) !void {
        if (now - self.last_heartbeat > self.heartbeat_interval_ms) {
            try self.sendHeartbeats();
            self.last_heartbeat = now;
        }
    }
    
    fn startElection(self: *RaftNode) !void {
        self.state = .candidate;
        self.persistent_state.current_term += 1;
        self.persistent_state.voted_for = self.node_id;
        
        try self.savePersistentState();
        
        // Reset election timeout
        self.resetElectionTimeout();
        
        // TODO: Implement proper vote counting and majority logic
        // For now, just log that election started
        std.debug.print("Node {} started election for term {}\n", .{ self.node_id, self.persistent_state.current_term });
    }
    
    fn handleRequestVote(self: *RaftNode, data: []const u8) ![]u8 {
        if (data.len != @sizeOf(RequestVoteRequest)) return error.InvalidMessage;
        
        const request = @as(*const RequestVoteRequest, @ptrCast(@alignCast(data.ptr))).*;
        
        var reply = RequestVoteReply{
            .term = self.persistent_state.current_term,
            .vote_granted = false,
        };
        
        // Update term if necessary
        if (request.term > self.persistent_state.current_term) {
            self.persistent_state.current_term = request.term;
            self.persistent_state.voted_for = null;
            self.state = .follower;
            try self.savePersistentState();
        }
        
        // Grant vote if conditions are met
        if (request.term == self.persistent_state.current_term and
            (self.persistent_state.voted_for == null or self.persistent_state.voted_for == request.candidate_id) and
            self.isLogUpToDate(request.last_log_index, request.last_log_term))
        {
            reply.vote_granted = true;
            self.persistent_state.voted_for = request.candidate_id;
            try self.savePersistentState();
            self.resetElectionTimeout();
        }
        
        reply.term = self.persistent_state.current_term;
        
        // Serialize reply
        const response = try self.allocator.alloc(u8, @sizeOf(RequestVoteReply));
        @memcpy(response, std.mem.asBytes(&reply));
        return response;
    }
    
    fn handleAppendEntries(self: *RaftNode, data: []const u8) ![]u8 {
        if (data.len < @sizeOf(AppendEntriesRequest)) return error.InvalidMessage;
        
        const request = @as(*const AppendEntriesRequest, @ptrCast(@alignCast(data.ptr))).*;
        const entries_data = data[@sizeOf(AppendEntriesRequest)..];
        
        var reply = AppendEntriesReply{
            .term = self.persistent_state.current_term,
            .success = false,
            .match_index = 0,
        };
        
        // Update term if necessary
        if (request.term > self.persistent_state.current_term) {
            self.persistent_state.current_term = request.term;
            self.persistent_state.voted_for = null;
            self.state = .follower;
            try self.savePersistentState();
        }
        
        // Reset election timeout on valid leader contact
        if (request.term >= self.persistent_state.current_term) {
            self.resetElectionTimeout();
            self.state = .follower;
        }
        
        // Check log consistency
        if (request.term == self.persistent_state.current_term) {
            if (self.checkLogConsistency(request.prev_log_index, request.prev_log_term)) {
                // Append new entries
                try self.appendNewEntries(entries_data, request.entry_count);
                
                // Update commit index
                if (request.leader_commit > self.volatile_state.commit_index) {
                    self.volatile_state.commit_index = @min(request.leader_commit, self.getLastLogIndex());
                }
                
                reply.success = true;
                reply.match_index = self.getLastLogIndex();
            }
        }
        
        reply.term = self.persistent_state.current_term;
        
        // Serialize reply
        const response = try self.allocator.alloc(u8, @sizeOf(AppendEntriesReply));
        @memcpy(response, std.mem.asBytes(&reply));
        return response;
    }
    
    fn handleInstallSnapshot(self: *RaftNode, data: []const u8) ![]u8 {
        // TODO: Implement snapshot installation
        _ = self; // Will be used when snapshot installation is implemented
        _ = data; // Will contain snapshot data
        return error.NotImplemented;
    }
    
    fn sendHeartbeats(self: *RaftNode) !void {
        if (self.state != .leader) return;
        
        // Send empty append entries as heartbeats
        for (self.cluster_config.nodes) |node| {
            if (node.id != self.node_id) {
                try self.sendAppendEntries(node.id);
            }
        }
    }
    
    fn sendAppendEntries(self: *RaftNode, node_id: u64) !void {
        // TODO: Implement append entries sending via network layer
        _ = self; // Will access network and log entries
        _ = node_id; // Target node for append entries
    }
    
    fn replicateToFollowers(self: *RaftNode) !void {
        if (self.state != .leader) return;
        
        for (self.cluster_config.nodes) |node| {
            if (node.id != self.node_id) {
                try self.sendAppendEntries(node.id);
            }
        }
    }
    
    pub fn resetElectionTimeout(self: *RaftNode) void {
        const random_offset = @as(u64, @intCast(std.crypto.random.int(u16))) % 150; // 0-150ms
        self.election_deadline = @as(u64, @intCast(std.time.milliTimestamp())) + self.election_timeout_ms + random_offset;
    }
    
    pub fn getLastLogIndex(self: *const RaftNode) u64 {
        if (self.log_entries.items.len == 0) return 0;
        return self.log_entries.items[self.log_entries.items.len - 1].index;
    }
    
    pub fn getLastLogTerm(self: *const RaftNode) u64 {
        if (self.log_entries.items.len == 0) return 0;
        return self.log_entries.items[self.log_entries.items.len - 1].term;
    }
    
    pub fn isLogUpToDate(self: *const RaftNode, last_log_index: u64, last_log_term: u64) bool {
        const my_last_term = self.getLastLogTerm();
        const my_last_index = self.getLastLogIndex();
        
        if (last_log_term != my_last_term) {
            return last_log_term > my_last_term;
        }
        return last_log_index >= my_last_index;
    }
    
    pub fn checkLogConsistency(self: *const RaftNode, prev_log_index: u64, prev_log_term: u64) bool {
        if (prev_log_index == 0) return true; // Empty log case
        
        if (prev_log_index > self.getLastLogIndex()) return false;
        
        // Find entry at prev_log_index
        for (self.log_entries.items) |entry| {
            if (entry.index == prev_log_index) {
                return entry.term == prev_log_term;
            }
        }
        return false;
    }
    
    fn appendNewEntries(self: *RaftNode, entries_data: []const u8, entry_count: u32) !void {
        // TODO: Parse and append entries from serialized data
        _ = self; // Will modify log_entries and log_data
        _ = entries_data; // Serialized log entries to parse
        _ = entry_count; // Number of entries in the data
    }
    
    fn savePersistentState(self: *RaftNode) !void {
        // Save state to disk for crash recovery
        const state_path = try std.fs.path.join(self.allocator, &[_][]const u8{ "raft_state.bin" });
        defer self.allocator.free(state_path);
        
        try self.persistent_state.save(self.allocator, state_path);
    }
};

/// Network layer interface (to be implemented)
pub const NetworkLayer = struct {
    pub fn sendRequestVote(self: *NetworkLayer, node_id: u64, request: RequestVoteRequest) !void {
        _ = self;
        _ = node_id;
        _ = request;
        // TODO: Implement network sending
    }
    
    pub fn sendAppendEntries(self: *NetworkLayer, node_id: u64, request: AppendEntriesRequest, entries: []const u8) !void {
        _ = self;
        _ = node_id;
        _ = request;
        _ = entries;
        // TODO: Implement network sending
    }
};

/// Calculate CRC32 checksum for data integrity
fn calculateChecksum(data: []const u8) u32 {
    const Crc32 = std.hash.Crc32;
    return Crc32.hash(data);
} 