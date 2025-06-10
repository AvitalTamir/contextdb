const std = @import("std");
const testing = std.testing;

/// Consistent Hashing Ring for Distributed Data Partitioning
/// Implements a hash ring with virtual nodes for even data distribution
/// Based on Amazon Dynamo's approach with TigerBeetle-style deterministic behavior

/// Hash ring configuration
pub const HashRingConfig = struct {
    virtual_nodes_per_node: u16 = 150, // Virtual nodes for load balancing
    replication_factor: u8 = 3, // Number of replicas per data item
    hash_function: HashFunction = .fnv1a, // Hash function to use
    
    pub const HashFunction = enum {
        fnv1a,    // Fast non-cryptographic hash
        crc32,    // Hardware-accelerated on many platforms
        xxhash,   // Very fast hash function
    };
};

/// Node information in the hash ring
pub const RingNode = packed struct {
    node_id: u64,
    virtual_node_id: u16, // Which virtual node this represents
    hash: u64, // Position on the ring
    is_alive: bool = true,
    
    pub fn init(node_id: u64, virtual_node_id: u16, hash: u64) RingNode {
        return RingNode{
            .node_id = node_id,
            .virtual_node_id = virtual_node_id,
            .hash = hash,
        };
    }
    
    /// Create deterministic virtual node identifier
    pub fn virtualNodeKey(node_id: u64, virtual_id: u16) u64 {
        // Combine node ID and virtual ID deterministically
        return (@as(u64, node_id) << 16) | @as(u64, virtual_id);
    }
};

/// Partition ownership information
pub const PartitionInfo = struct {
    primary_node: u64,          // Primary replica owner
    replica_nodes: []u64,       // Additional replica owners
    partition_start: u64,       // Start of hash range
    partition_end: u64,         // End of hash range (exclusive)
    
    pub fn deinit(self: *PartitionInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.replica_nodes);
    }
    
    /// Check if a node owns this partition (primary or replica)
    pub fn ownsPartition(self: *const PartitionInfo, node_id: u64) bool {
        if (self.primary_node == node_id) return true;
        
        for (self.replica_nodes) |replica| {
            if (replica == node_id) return true;
        }
        return false;
    }
};

/// Consistent Hash Ring
pub const ConsistentHashRing = struct {
    allocator: std.mem.Allocator,
    config: HashRingConfig,
    
    // Ring storage (sorted by hash value)
    ring_nodes: std.ArrayList(RingNode),
    node_alive_status: std.AutoHashMap(u64, bool),
    
    // Cached partition mappings
    partition_cache: std.AutoHashMap(u64, u64), // hash -> primary_node
    cache_valid: bool = false,
    
    // Statistics
    total_virtual_nodes: u64 = 0,
    rebalance_count: u64 = 0,
    
    pub fn init(allocator: std.mem.Allocator, config: HashRingConfig) ConsistentHashRing {
        return ConsistentHashRing{
            .allocator = allocator,
            .config = config,
            .ring_nodes = std.ArrayList(RingNode).init(allocator),
            .node_alive_status = std.AutoHashMap(u64, bool).init(allocator),
            .partition_cache = std.AutoHashMap(u64, u64).init(allocator),
        };
    }
    
    pub fn deinit(self: *ConsistentHashRing) void {
        self.ring_nodes.deinit();
        self.node_alive_status.deinit();
        self.partition_cache.deinit();
    }
    
    /// Add a node to the hash ring
    pub fn addNode(self: *ConsistentHashRing, node_id: u64) !void {
        // Check if node already exists
        if (self.node_alive_status.contains(node_id)) {
            return error.NodeAlreadyExists;
        }
        
        // Add virtual nodes for this physical node
        for (0..self.config.virtual_nodes_per_node) |i| {
            const virtual_id = @as(u16, @intCast(i));
            const virtual_key = RingNode.virtualNodeKey(node_id, virtual_id);
            const hash = self.calculateHash(virtual_key);
            
            const ring_node = RingNode.init(node_id, virtual_id, hash);
            try self.ring_nodes.append(ring_node);
        }
        
        // Mark node as alive
        try self.node_alive_status.put(node_id, true);
        
        // Sort ring by hash value for efficient lookups
        std.mem.sort(RingNode, self.ring_nodes.items, {}, compareRingNodes);
        
        // Invalidate cache and update statistics
        self.cache_valid = false;
        self.total_virtual_nodes += self.config.virtual_nodes_per_node;
        self.rebalance_count += 1;
        
        std.debug.print("Added node {} with {} virtual nodes to hash ring\n", 
            .{ node_id, self.config.virtual_nodes_per_node });
    }
    
    /// Remove a node from the hash ring
    pub fn removeNode(self: *ConsistentHashRing, node_id: u64) !void {
        if (!self.node_alive_status.contains(node_id)) {
            return error.NodeNotFound;
        }
        
        // Remove all virtual nodes for this physical node
        var i: usize = 0;
        while (i < self.ring_nodes.items.len) {
            if (self.ring_nodes.items[i].node_id == node_id) {
                _ = self.ring_nodes.swapRemove(i);
            } else {
                i += 1;
            }
        }
        
        // Remove from alive status
        _ = self.node_alive_status.remove(node_id);
        
        // Re-sort ring
        std.mem.sort(RingNode, self.ring_nodes.items, {}, compareRingNodes);
        
        // Invalidate cache and update statistics
        self.cache_valid = false;
        self.total_virtual_nodes -= self.config.virtual_nodes_per_node;
        self.rebalance_count += 1;
        
        std.debug.print("Removed node {} from hash ring\n", .{node_id});
    }
    
    /// Mark a node as failed (but keep in ring for recovery)
    pub fn markNodeFailed(self: *ConsistentHashRing, node_id: u64) !void {
        if (!self.node_alive_status.contains(node_id)) {
            return error.NodeNotFound;
        }
        
        try self.node_alive_status.put(node_id, false);
        
        // Mark all virtual nodes as not alive
        for (self.ring_nodes.items) |*ring_node| {
            if (ring_node.node_id == node_id) {
                ring_node.is_alive = false;
            }
        }
        
        self.cache_valid = false;
        std.debug.print("Marked node {} as failed\n", .{node_id});
    }
    
    /// Mark a node as recovered
    pub fn markNodeRecovered(self: *ConsistentHashRing, node_id: u64) !void {
        if (!self.node_alive_status.contains(node_id)) {
            return error.NodeNotFound;
        }
        
        try self.node_alive_status.put(node_id, true);
        
        // Mark all virtual nodes as alive
        for (self.ring_nodes.items) |*ring_node| {
            if (ring_node.node_id == node_id) {
                ring_node.is_alive = true;
            }
        }
        
        self.cache_valid = false;
        std.debug.print("Marked node {} as recovered\n", .{node_id});
    }
    
    /// Find the primary node responsible for a data key
    pub fn findPrimaryNode(self: *ConsistentHashRing, data_key: []const u8) !u64 {
        const hash = self.calculateHash(std.hash_map.hashString(data_key));
        return self.findNodeByHash(hash);
    }
    
    /// Find all replica nodes for a data key (including primary)
    pub fn findReplicaNodes(self: *ConsistentHashRing, data_key: []const u8) ![]u64 {
        const hash = self.calculateHash(std.hash_map.hashString(data_key));
        return self.findReplicaNodesByHash(hash);
    }
    
    /// Find node by hash position
    pub fn findNodeByHash(self: *ConsistentHashRing, hash: u64) !u64 {
        if (self.ring_nodes.items.len == 0) {
            return error.NoNodesAvailable;
        }
        
        // Check cache first
        if (self.cache_valid) {
            if (self.partition_cache.get(hash)) |cached_node| {
                return cached_node;
            }
        }
        
        // Binary search for the first node with hash >= target hash
        var low: usize = 0;
        var high: usize = self.ring_nodes.items.len;
        
        while (low < high) {
            const mid = low + (high - low) / 2;
            const ring_node = self.ring_nodes.items[mid];
            
            if (ring_node.hash >= hash and ring_node.is_alive) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }
        
        // If no node found after hash, wrap around to first node
        var node_index = if (low < self.ring_nodes.items.len) low else 0;
        
        // Find first alive node starting from this position
        const start_index = node_index;
        while (true) {
            const ring_node = self.ring_nodes.items[node_index];
            if (ring_node.is_alive) {
                // Cache the result
                if (!self.cache_valid) {
                    self.rebuildCache(); // Cache rebuild is now infallible
                }
                return ring_node.node_id;
            }
            
            node_index = (node_index + 1) % self.ring_nodes.items.len;
            if (node_index == start_index) {
                return error.NoAliveNodesAvailable;
            }
        }
    }
    
    /// Find replica nodes by hash (including primary)
    pub fn findReplicaNodesByHash(self: *ConsistentHashRing, hash: u64) ![]u64 {
        if (self.ring_nodes.items.len == 0) {
            return error.NoNodesAvailable;
        }
        
        var replica_nodes = std.ArrayList(u64).init(self.allocator);
        defer replica_nodes.deinit();
        
        var unique_nodes = std.AutoHashMap(u64, bool).init(self.allocator);
        defer unique_nodes.deinit();
        
        // Find starting position
        var node_index: usize = 0;
        for (self.ring_nodes.items, 0..) |ring_node, i| {
            if (ring_node.hash >= hash) {
                node_index = i;
                break;
            }
        }
        
        // Collect unique alive nodes up to replication factor
        const target_replicas = @min(self.config.replication_factor, self.getUniqueAliveNodeCount());
        var collected_replicas: u8 = 0;
        const start_index = node_index;
        
        while (collected_replicas < target_replicas) {
            const ring_node = self.ring_nodes.items[node_index];
            
            if (ring_node.is_alive and !unique_nodes.contains(ring_node.node_id)) {
                try replica_nodes.append(ring_node.node_id);
                try unique_nodes.put(ring_node.node_id, true);
                collected_replicas += 1;
            }
            
            node_index = (node_index + 1) % self.ring_nodes.items.len;
            
            // Avoid infinite loop if we've checked all nodes
            if (node_index == start_index and collected_replicas == 0) {
                return error.NoAliveNodesAvailable;
            }
        }
        
        return replica_nodes.toOwnedSlice();
    }
    
    /// Get partition information for a hash range
    pub fn getPartitionInfo(self: *ConsistentHashRing, start_hash: u64, end_hash: u64) !PartitionInfo {
        const primary_node = try self.findNodeByHash(start_hash);
        const replica_nodes = try self.findReplicaNodesByHash(start_hash);
        
        // Remove primary from replica list
        var filtered_replicas = std.ArrayList(u64).init(self.allocator);
        defer filtered_replicas.deinit();
        
        for (replica_nodes) |replica| {
            if (replica != primary_node) {
                try filtered_replicas.append(replica);
            }
        }
        
        return PartitionInfo{
            .primary_node = primary_node,
            .replica_nodes = try filtered_replicas.toOwnedSlice(),
            .partition_start = start_hash,
            .partition_end = end_hash,
        };
    }
    
    /// Get all alive node IDs
    pub fn getAliveNodes(self: *ConsistentHashRing) ![]u64 {
        var alive_nodes = std.ArrayList(u64).init(self.allocator);
        defer alive_nodes.deinit();
        
        var unique_nodes = std.AutoHashMap(u64, bool).init(self.allocator);
        defer unique_nodes.deinit();
        
        for (self.ring_nodes.items) |ring_node| {
            if (ring_node.is_alive and !unique_nodes.contains(ring_node.node_id)) {
                try alive_nodes.append(ring_node.node_id);
                try unique_nodes.put(ring_node.node_id, true);
            }
        }
        
        return alive_nodes.toOwnedSlice();
    }
    
    /// Get number of unique alive nodes
    pub fn getUniqueAliveNodeCount(self: *ConsistentHashRing) u8 {
        var unique_nodes = std.AutoHashMap(u64, bool).init(self.allocator);
        defer unique_nodes.deinit();
        
        for (self.ring_nodes.items) |ring_node| {
            if (ring_node.is_alive) {
                unique_nodes.put(ring_node.node_id, true) catch continue;
            }
        }
        
        return @intCast(unique_nodes.count());
    }
    
    /// Calculate hash using configured hash function
    fn calculateHash(self: *ConsistentHashRing, input: u64) u64 {
        switch (self.config.hash_function) {
            .fnv1a => return hashFnv1a(input),
            .crc32 => return @as(u64, std.hash.Crc32.hash(std.mem.asBytes(&input))),
            .xxhash => return hashXxHash(input),
        }
    }
    
    /// Rebuild partition cache for faster lookups
    fn rebuildCache(self: *ConsistentHashRing) void {
        self.partition_cache.clearAndFree();
        
        // Skip cache rebuilding if no nodes available
        if (self.ring_nodes.items.len == 0) {
            self.cache_valid = true;
            return;
        }
        
        // Pre-compute common hash positions
        const cache_resolution = 100; // Cache every 100th hash position (smaller for performance)
        const hash_step = std.math.maxInt(u64) / cache_resolution;
        
        var hash: u64 = 0;
        var cached_count: u32 = 0;
        while (hash < std.math.maxInt(u64) - hash_step and cached_count < cache_resolution) : (hash += hash_step) {
            // Find node using simplified logic to avoid error set issues
            var node_found: ?u64 = null;
            for (self.ring_nodes.items) |ring_node| {
                if (ring_node.hash >= hash and ring_node.is_alive) {
                    node_found = ring_node.node_id;
                    break;
                }
            }
            
            if (node_found) |node| {
                self.partition_cache.put(hash, node) catch break; // Stop on allocation error
                cached_count += 1;
            }
        }
        
        self.cache_valid = true;
    }
};

/// Compare ring nodes by hash for sorting
fn compareRingNodes(context: void, a: RingNode, b: RingNode) bool {
    _ = context;
    return a.hash < b.hash;
}

/// FNV-1a hash implementation
fn hashFnv1a(input: u64) u64 {
    const FNV_OFFSET_BASIS: u64 = 14695981039346656037;
    const FNV_PRIME: u64 = 1099511628211;
    
    var hash = FNV_OFFSET_BASIS;
    const bytes = std.mem.asBytes(&input);
    
    for (bytes) |byte| {
        hash ^= byte;
        hash = hash *% FNV_PRIME;
    }
    
    return hash;
}

/// XXHash implementation (simplified)
fn hashXxHash(input: u64) u64 {
    // Simplified XXHash-like algorithm
    const PRIME2: u64 = 14029467366897019727;
    const PRIME3: u64 = 1609587929392839161;
    
    var hash = input;
    hash ^= hash >> 33;
    hash = hash *% PRIME2;
    hash ^= hash >> 29;
    hash = hash *% PRIME3;
    hash ^= hash >> 32;
    
    return hash;
}

// =============================================================================
// Tests
// =============================================================================

test "ConsistentHashRing: basic node operations" {
    var ring = ConsistentHashRing.init(testing.allocator, HashRingConfig{
        .virtual_nodes_per_node = 10,
        .replication_factor = 3,
    });
    defer ring.deinit();
    
    // Add nodes
    try ring.addNode(1);
    try ring.addNode(2);
    try ring.addNode(3);
    
    // Check node count
    try testing.expect(ring.ring_nodes.items.len == 30); // 3 nodes × 10 virtual nodes
    try testing.expect(ring.getUniqueAliveNodeCount() == 3);
    
    // Test node lookup
    const node = try ring.findPrimaryNode("test_key");
    try testing.expect(node >= 1 and node <= 3);
    
    // Test replica nodes
    const replicas = try ring.findReplicaNodes("test_key");
    defer testing.allocator.free(replicas);
    try testing.expect(replicas.len == 3); // All nodes as replicas
}

test "ConsistentHashRing: node failure and recovery" {
    var ring = ConsistentHashRing.init(testing.allocator, HashRingConfig{
        .virtual_nodes_per_node = 5,
        .replication_factor = 2,
    });
    defer ring.deinit();
    
    try ring.addNode(1);
    try ring.addNode(2);
    try ring.addNode(3);
    
    // Mark node as failed
    try ring.markNodeFailed(2);
    try testing.expect(ring.getUniqueAliveNodeCount() == 2);
    
    // Verify failover works
    const node = try ring.findPrimaryNode("test_key");
    try testing.expect(node == 1 or node == 3); // Node 2 should be excluded
    
    // Recover node
    try ring.markNodeRecovered(2);
    try testing.expect(ring.getUniqueAliveNodeCount() == 3);
}

test "ConsistentHashRing: replication factor" {
    var ring = ConsistentHashRing.init(testing.allocator, HashRingConfig{
        .virtual_nodes_per_node = 20,
        .replication_factor = 2,
    });
    defer ring.deinit();
    
    try ring.addNode(1);
    try ring.addNode(2);
    try ring.addNode(3);
    try ring.addNode(4);
    
    const replicas = try ring.findReplicaNodes("test_key");
    defer testing.allocator.free(replicas);
    
    try testing.expect(replicas.len == 2); // Should respect replication factor
    
    // Verify all replicas are unique
    try testing.expect(replicas[0] != replicas[1]);
}

test "ConsistentHashRing: data distribution" {
    var ring = ConsistentHashRing.init(testing.allocator, HashRingConfig{
        .virtual_nodes_per_node = 50,
        .replication_factor = 1,
    });
    defer ring.deinit();
    
    try ring.addNode(1);
    try ring.addNode(2);
    try ring.addNode(3);
    
    // Test distribution across many keys
    var node_counts = [_]u32{0} ** 4; // Index 0 unused, 1-3 for nodes
    
    for (0..1000) |i| {
        var key_buf: [20]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key_{}", .{i});
        const node = try ring.findPrimaryNode(key);
        node_counts[node] += 1;
    }
    
    // Each node should get roughly 1000/3 = ~333 keys
    // Allow some variance due to hashing
    for (1..4) |node_id| {
        const count = node_counts[node_id];
        try testing.expect(count > 250 and count < 450); // 25% variance allowed
    }
} 