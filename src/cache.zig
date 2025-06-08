const std = @import("std");
const types = @import("types.zig");

/// High-Performance Caching System
/// Provides intelligent caching with multiple eviction policies
/// Following TigerBeetle-style programming: deterministic, comprehensive, zero dependencies

/// Cache eviction policies
pub const EvictionPolicy = enum {
    /// Least Recently Used - evict the least recently accessed item
    lru,
    /// Least Frequently Used - evict the least frequently accessed item
    lfu,
    /// First In First Out - evict the oldest item
    fifo,
    /// Random - evict a random item (for testing/comparison)
    random,
    /// Time-based - evict items based on TTL
    ttl,
};

/// Cache statistics for monitoring and optimization
pub const CacheStats = struct {
    hits: u64,
    misses: u64,
    evictions: u64,
    inserts: u64,
    updates: u64,
    total_size: u64,
    max_size: u64,
    avg_access_time_ns: u64,
    
    pub fn init(max_size: u64) CacheStats {
        return CacheStats{
            .hits = 0,
            .misses = 0,
            .evictions = 0,
            .inserts = 0,
            .updates = 0,
            .total_size = 0,
            .max_size = max_size,
            .avg_access_time_ns = 0,
        };
    }
    
    pub fn getHitRatio(self: CacheStats) f32 {
        const total_accesses = self.hits + self.misses;
        if (total_accesses == 0) return 0.0;
        return @as(f32, @floatFromInt(self.hits)) / @as(f32, @floatFromInt(total_accesses));
    }
    
    pub fn getUtilization(self: CacheStats) f32 {
        if (self.max_size == 0) return 0.0;
        return @as(f32, @floatFromInt(self.total_size)) / @as(f32, @floatFromInt(self.max_size));
    }
    
    pub fn recordHit(self: *CacheStats, access_time_ns: u64) void {
        self.hits += 1;
        self.updateAverageAccessTime(access_time_ns);
    }
    
    pub fn recordMiss(self: *CacheStats, access_time_ns: u64) void {
        self.misses += 1;
        self.updateAverageAccessTime(access_time_ns);
    }
    
    fn updateAverageAccessTime(self: *CacheStats, access_time_ns: u64) void {
        const total_accesses = self.hits + self.misses;
        if (total_accesses == 1) {
            self.avg_access_time_ns = access_time_ns;
        } else {
            // Exponential moving average
            const alpha = 0.1;
            const new_avg = @as(f64, @floatFromInt(self.avg_access_time_ns)) * (1.0 - alpha) + 
                          @as(f64, @floatFromInt(access_time_ns)) * alpha;
            self.avg_access_time_ns = @intFromFloat(new_avg);
        }
    }
};

/// Cache configuration
pub const CacheConfig = struct {
    max_size: u64,
    eviction_policy: EvictionPolicy = .lru,
    ttl_seconds: ?u64 = null, // Time-to-live in seconds
    enable_stats: bool = true,
    initial_capacity: u32 = 1000,
    load_factor_threshold: f32 = 0.75, // When to resize
};

/// Cache entry metadata
const CacheEntry = struct {
    key: u64,
    value: CacheValue,
    access_count: u32,
    last_access_time: u64, // Nanoseconds since epoch
    insertion_time: u64,
    size: u64, // Size in bytes
    
    pub fn init(key: u64, value: CacheValue, size: u64) CacheEntry {
        const now = std.time.nanoTimestamp();
        return CacheEntry{
            .key = key,
            .value = value,
            .access_count = 1,
            .last_access_time = @intCast(now),
            .insertion_time = @intCast(now),
            .size = size,
        };
    }
    
    pub fn touch(self: *CacheEntry) void {
        self.access_count += 1;
        self.last_access_time = @intCast(std.time.nanoTimestamp());
    }
    
    pub fn isExpired(self: CacheEntry, ttl_seconds: u64) bool {
        const now = @as(u64, @intCast(std.time.nanoTimestamp()));
        const ttl_ns = ttl_seconds * 1_000_000_000;
        return (now - self.last_access_time) > ttl_ns;
    }
    
    pub fn getAge(self: CacheEntry) u64 {
        const now = @as(u64, @intCast(std.time.nanoTimestamp()));
        return now - self.insertion_time;
    }
};

/// Cached value types - supporting different data types for maximum flexibility
pub const CacheValue = union(enum) {
    node: types.Node,
    edge: types.Edge,
    vector: types.Vector,
    similarity_results: std.ArrayList(types.SimilarityResult),
    node_list: std.ArrayList(types.Node),
    edge_list: std.ArrayList(types.Edge),
    raw_data: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    
    pub fn deinit(self: CacheValue, allocator: std.mem.Allocator) void {
        switch (self) {
            .similarity_results => |list| {
                var mut_list = list;
                mut_list.deinit();
            },
            .node_list => |list| {
                var mut_list = list;
                mut_list.deinit();
            },
            .edge_list => |list| {
                var mut_list = list;
                mut_list.deinit();
            },
            .raw_data => |data| {
                allocator.free(data);
            },
            else => {
                // Other types don't need explicit cleanup
            },
        }
    }
    
    pub fn getSize(self: CacheValue) u64 {
        return switch (self) {
            .node => @sizeOf(types.Node),
            .edge => @sizeOf(types.Edge),
            .vector => @sizeOf(types.Vector),
            .similarity_results => |list| list.items.len * @sizeOf(types.SimilarityResult),
            .node_list => |list| list.items.len * @sizeOf(types.Node),
            .edge_list => |list| list.items.len * @sizeOf(types.Edge),
            .raw_data => |data| data.len,
            .integer => @sizeOf(i64),
            .float => @sizeOf(f64),
            .boolean => @sizeOf(bool),
        };
    }
    
    pub fn clone(self: CacheValue, allocator: std.mem.Allocator) !CacheValue {
        return switch (self) {
            .node => |n| CacheValue{ .node = n },
            .edge => |e| CacheValue{ .edge = e },
            .vector => |v| CacheValue{ .vector = v },
            .similarity_results => |list| blk: {
                var new_list = std.ArrayList(types.SimilarityResult).init(allocator);
                try new_list.appendSlice(list.items);
                break :blk CacheValue{ .similarity_results = new_list };
            },
            .node_list => |list| blk: {
                var new_list = std.ArrayList(types.Node).init(allocator);
                try new_list.appendSlice(list.items);
                break :blk CacheValue{ .node_list = new_list };
            },
            .edge_list => |list| blk: {
                var new_list = std.ArrayList(types.Edge).init(allocator);
                try new_list.appendSlice(list.items);
                break :blk CacheValue{ .edge_list = new_list };
            },
            .raw_data => |data| blk: {
                const new_data = try allocator.dupe(u8, data);
                break :blk CacheValue{ .raw_data = new_data };
            },
            .integer => |i| CacheValue{ .integer = i },
            .float => |f| CacheValue{ .float = f },
            .boolean => |b| CacheValue{ .boolean = b },
        };
    }
};

/// Doubly-linked list node for LRU tracking
const LRUNode = struct {
    key: u64,
    prev: ?*LRUNode,
    next: ?*LRUNode,
    
    pub fn init(key: u64) LRUNode {
        return LRUNode{
            .key = key,
            .prev = null,
            .next = null,
        };
    }
};

/// LRU list for efficient least-recently-used tracking
const LRUList = struct {
    allocator: std.mem.Allocator,
    head: ?*LRUNode,
    tail: ?*LRUNode,
    node_map: std.AutoHashMap(u64, *LRUNode),
    
    pub fn init(allocator: std.mem.Allocator) LRUList {
        return LRUList{
            .allocator = allocator,
            .head = null,
            .tail = null,
            .node_map = std.AutoHashMap(u64, *LRUNode).init(allocator),
        };
    }
    
    pub fn deinit(self: *LRUList) void {
        var current = self.head;
        while (current) |node| {
            const next = node.next;
            self.allocator.destroy(node);
            current = next;
        }
        self.node_map.deinit();
    }
    
    pub fn touch(self: *LRUList, key: u64) !void {
        if (self.node_map.get(key)) |node| {
            // Move to front
            self.removeNode(node);
            self.addToFront(node);
        } else {
            // Create new node
            const node = try self.allocator.create(LRUNode);
            node.* = LRUNode.init(key);
            try self.node_map.put(key, node);
            self.addToFront(node);
        }
    }
    
    pub fn removeLRU(self: *LRUList) ?u64 {
        if (self.tail) |tail_node| {
            const key = tail_node.key;
            self.removeNode(tail_node);
            _ = self.node_map.remove(key);
            self.allocator.destroy(tail_node);
            return key;
        }
        return null;
    }
    
    pub fn remove(self: *LRUList, key: u64) void {
        if (self.node_map.get(key)) |node| {
            self.removeNode(node);
            _ = self.node_map.remove(key);
            self.allocator.destroy(node);
        }
    }
    
    fn addToFront(self: *LRUList, node: *LRUNode) void {
        node.next = self.head;
        node.prev = null;
        
        if (self.head) |head| {
            head.prev = node;
        } else {
            self.tail = node;
        }
        
        self.head = node;
    }
    
    fn removeNode(self: *LRUList, node: *LRUNode) void {
        if (node.prev) |prev| {
            prev.next = node.next;
        } else {
            self.head = node.next;
        }
        
        if (node.next) |next| {
            next.prev = node.prev;
        } else {
            self.tail = node.prev;
        }
        
        node.prev = null;
        node.next = null;
    }
};

/// Main cache implementation
pub const Cache = struct {
    allocator: std.mem.Allocator,
    config: CacheConfig,
    entries: std.AutoHashMap(u64, CacheEntry),
    lru_list: LRUList,
    stats: CacheStats,
    prng: std.Random.DefaultPrng, // For random eviction
    
    pub fn init(allocator: std.mem.Allocator, config: CacheConfig) Cache {
        return Cache{
            .allocator = allocator,
            .config = config,
            .entries = std.AutoHashMap(u64, CacheEntry).init(allocator),
            .lru_list = LRUList.init(allocator),
            .stats = CacheStats.init(config.max_size),
            .prng = std.Random.DefaultPrng.init(42), // Deterministic for testing
        };
    }
    
    pub fn deinit(self: *Cache) void {
        // Clean up all cached values
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.value.deinit(self.allocator);
        }
        
        self.entries.deinit();
        self.lru_list.deinit();
    }
    
    /// Get an item from the cache
    pub fn get(self: *Cache, key: u64) ?CacheValue {
        var timer = std.time.Timer.start() catch return null;
        
        if (self.entries.getPtr(key)) |entry| {
            // Check TTL expiration
            if (self.config.ttl_seconds) |ttl| {
                if (entry.isExpired(ttl)) {
                    self.remove(key);
                    const elapsed = timer.lap();
                    if (self.config.enable_stats) {
                        self.stats.recordMiss(elapsed);
                    }
                    return null;
                }
            }
            
            // Update access information
            entry.touch();
            
            // Update LRU position if using LRU policy
            if (self.config.eviction_policy == .lru) {
                self.lru_list.touch(key) catch {};
            }
            
            const elapsed = timer.lap();
            if (self.config.enable_stats) {
                self.stats.recordHit(elapsed);
            }
            
            return entry.value.clone(self.allocator) catch null;
        } else {
            const elapsed = timer.lap();
            if (self.config.enable_stats) {
                self.stats.recordMiss(elapsed);
            }
            return null;
        }
    }
    
    /// Put an item into the cache
    pub fn put(self: *Cache, key: u64, value: CacheValue) !void {
        const value_size = value.getSize();
        
        // Check if we need to evict items to make space
        while (self.shouldEvict(value_size)) {
            try self.evictOne();
        }
        
        // Check if key already exists (update case)
        if (self.entries.getPtr(key)) |existing_entry| {
            // Clean up old value
            existing_entry.value.deinit(self.allocator);
            
            // Update with new value
            existing_entry.value = try value.clone(self.allocator);
            existing_entry.touch();
            
            // Update size tracking
            self.stats.total_size = self.stats.total_size - existing_entry.size + value_size;
            existing_entry.size = value_size;
            
            if (self.config.enable_stats) {
                self.stats.updates += 1;
            }
            
            // Update LRU position
            if (self.config.eviction_policy == .lru) {
                try self.lru_list.touch(key);
            }
        } else {
            // Insert new entry
            const entry = CacheEntry.init(key, try value.clone(self.allocator), value_size);
            try self.entries.put(key, entry);
            
            // Update size tracking
            self.stats.total_size += value_size;
            
            if (self.config.enable_stats) {
                self.stats.inserts += 1;
            }
            
            // Add to LRU list
            if (self.config.eviction_policy == .lru) {
                try self.lru_list.touch(key);
            }
        }
    }
    
    /// Remove an item from the cache
    pub fn remove(self: *Cache, key: u64) void {
        if (self.entries.fetchRemove(key)) |kv| {
            // Clean up the value
            kv.value.value.deinit(self.allocator);
            
            // Update size tracking
            self.stats.total_size -= kv.value.size;
            
            // Remove from LRU list
            if (self.config.eviction_policy == .lru) {
                self.lru_list.remove(key);
            }
        }
    }
    
    /// Clear all items from the cache
    pub fn clear(self: *Cache) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.value.deinit(self.allocator);
        }
        
        self.entries.clearRetainingCapacity();
        self.lru_list.deinit();
        self.lru_list = LRUList.init(self.allocator);
        self.stats.total_size = 0;
    }
    
    /// Get cache statistics
    pub fn getStats(self: *const Cache) CacheStats {
        return self.stats;
    }
    
    /// Check if the cache contains a key
    pub fn contains(self: *const Cache, key: u64) bool {
        return self.entries.contains(key);
    }
    
    /// Get the number of items in the cache
    pub fn size(self: *const Cache) u32 {
        return @intCast(self.entries.count());
    }
    
    /// Get all keys in the cache
    pub fn getKeys(self: *const Cache) !std.ArrayList(u64) {
        var keys = std.ArrayList(u64).init(self.allocator);
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            try keys.append(entry.key_ptr.*);
        }
        return keys;
    }
    
    /// Perform cache maintenance (cleanup expired items, etc.)
    pub fn maintenance(self: *Cache) !void {
        if (self.config.ttl_seconds) |ttl| {
            var keys_to_remove = std.ArrayList(u64).init(self.allocator);
            defer keys_to_remove.deinit();
            
            var iter = self.entries.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.isExpired(ttl)) {
                    try keys_to_remove.append(entry.key_ptr.*);
                }
            }
            
            for (keys_to_remove.items) |key| {
                self.remove(key);
            }
        }
    }
    
    // Private methods
    
    fn shouldEvict(self: *const Cache, additional_size: u64) bool {
        return (self.stats.total_size + additional_size) > self.config.max_size;
    }
    
    fn evictOne(self: *Cache) !void {
        const key_to_evict = switch (self.config.eviction_policy) {
            .lru => self.findLRUKey(),
            .lfu => self.findLFUKey(),
            .fifo => self.findFIFOKey(),
            .random => self.findRandomKey(),
            .ttl => self.findExpiredKey(),
        };
        
        if (key_to_evict) |key| {
            self.remove(key);
            if (self.config.enable_stats) {
                self.stats.evictions += 1;
            }
        }
    }
    
    fn findLRUKey(self: *Cache) ?u64 {
        return self.lru_list.removeLRU();
    }
    
    fn findLFUKey(self: *const Cache) ?u64 {
        var min_access_count: u32 = std.math.maxInt(u32);
        var lfu_key: ?u64 = null;
        
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.access_count < min_access_count) {
                min_access_count = entry.value_ptr.access_count;
                lfu_key = entry.key_ptr.*;
            }
        }
        
        return lfu_key;
    }
    
    fn findFIFOKey(self: *const Cache) ?u64 {
        var oldest_time: u64 = std.math.maxInt(u64);
        var fifo_key: ?u64 = null;
        
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.insertion_time < oldest_time) {
                oldest_time = entry.value_ptr.insertion_time;
                fifo_key = entry.key_ptr.*;
            }
        }
        
        return fifo_key;
    }
    
    fn findRandomKey(self: *Cache) ?u64 {
        const count = self.entries.count();
        if (count == 0) return null;
        
        const target_index = self.prng.random().intRangeAtMost(usize, 0, count - 1);
        var current_index: usize = 0;
        
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            if (current_index == target_index) {
                return entry.key_ptr.*;
            }
            current_index += 1;
        }
        
        return null;
    }
    
    fn findExpiredKey(self: *const Cache) ?u64 {
        if (self.config.ttl_seconds) |ttl| {
            var iter = self.entries.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.isExpired(ttl)) {
                    return entry.key_ptr.*;
                }
            }
        }
        return null;
    }
};

/// Multi-level cache system for hierarchical caching
pub const MultiLevelCache = struct {
    allocator: std.mem.Allocator,
    l1_cache: Cache, // Fast, small cache
    l2_cache: Cache, // Slower, larger cache
    
    pub fn init(allocator: std.mem.Allocator, l1_config: CacheConfig, l2_config: CacheConfig) MultiLevelCache {
        return MultiLevelCache{
            .allocator = allocator,
            .l1_cache = Cache.init(allocator, l1_config),
            .l2_cache = Cache.init(allocator, l2_config),
        };
    }
    
    pub fn deinit(self: *MultiLevelCache) void {
        self.l1_cache.deinit();
        self.l2_cache.deinit();
    }
    
    pub fn get(self: *MultiLevelCache, key: u64) ?CacheValue {
        // Try L1 first
        if (self.l1_cache.get(key)) |value| {
            return value;
        }
        
        // Try L2
        if (self.l2_cache.get(key)) |value| {
            // Promote to L1
            self.l1_cache.put(key, value) catch {};
            return value;
        }
        
        return null;
    }
    
    pub fn put(self: *MultiLevelCache, key: u64, value: CacheValue) !void {
        // Put in both caches
        try self.l1_cache.put(key, value);
        try self.l2_cache.put(key, value);
    }
    
    pub fn remove(self: *MultiLevelCache, key: u64) void {
        self.l1_cache.remove(key);
        self.l2_cache.remove(key);
    }
    
    pub fn getStats(self: *const MultiLevelCache) struct { l1: CacheStats, l2: CacheStats } {
        return .{
            .l1 = self.l1_cache.getStats(),
            .l2 = self.l2_cache.getStats(),
        };
    }
    
    pub fn maintenance(self: *MultiLevelCache) !void {
        try self.l1_cache.maintenance();
        try self.l2_cache.maintenance();
    }
};

/// Cache key generation utilities
pub const CacheKeys = struct {
    /// Generate cache key for vector similarity search
    pub fn vectorSimilarity(vector_id: u64, k: u32) u64 {
        return hashComponents(.{ vector_id, @as(u64, k) });
    }
    
    /// Generate cache key for graph traversal
    pub fn graphTraversal(start_node: u64, depth: u8) u64 {
        return hashComponents(.{ start_node, @as(u64, depth) });
    }
    
    /// Generate cache key for node data
    pub fn nodeData(node_id: u64) u64 {
        return hashComponents(.{node_id});
    }
    
    /// Generate cache key for edge data
    pub fn edgeData(from_id: u64, to_id: u64) u64 {
        return hashComponents(.{ from_id, to_id });
    }
    
    /// Generate cache key for complex queries
    pub fn complexQuery(query_hash: u64, params_hash: u64) u64 {
        return hashComponents(.{ query_hash, params_hash });
    }
    
    fn hashComponents(components: anytype) u64 {
        var hash: u64 = 14695981039346656037; // FNV offset basis
        
        inline for (components) |component| {
            hash ^= component;
            hash *%= 1099511628211; // FNV prime
        }
        
        return hash;
    }
}; 