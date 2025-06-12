const std = @import("std");

// Export modules for external use
pub const types = @import("types.zig");
pub const memory_types = @import("memory_types.zig");
pub const memory_manager = @import("memory_manager.zig");
pub const log = @import("log.zig");
pub const graph = @import("graph.zig");
pub const vector = @import("vector.zig");
pub const snapshot = @import("snapshot.zig");
pub const s3 = @import("s3.zig");
pub const query_optimizer = @import("query_optimizer.zig");
pub const cache = @import("cache.zig");
pub const parallel = @import("parallel.zig");
pub const persistent_index = @import("persistent_index.zig");
pub const raft = @import("raft.zig");
pub const raft_network = @import("raft_network.zig");
pub const distributed_memora = @import("distributed_memora.zig");
pub const http_api = @import("http_api.zig");
pub const monitoring = @import("monitoring.zig");
pub const config_mod = @import("config.zig");
pub const fuzzing = @import("fuzzing.zig");
pub const mcp_server = @import("mcp_server.zig");
pub const gossip = @import("gossip.zig");
pub const node_discovery = @import("node_discovery.zig");
pub const partitioning = @import("partitioning.zig");
pub const consistent_hashing = @import("consistent_hashing.zig");
pub const recovery = @import("recovery.zig");
pub const split_brain_protection = @import("split_brain_protection.zig");

// Local aliases for internal use
const types_local = types;
const log_local = log;
const graph_local = graph;
const vector_local = vector;
const snapshot_local = snapshot;
const s3_local = s3;
const persistent_index_local = persistent_index;

/// Memora - A hybrid vector and graph database
/// Inspired by TigerBeetle's design with Iceberg-style snapshots
pub const Memora = struct {
    allocator: std.mem.Allocator,
    
    // Core components
    append_log: log.AppendLog,
    graph_index: graph.GraphIndex,
    vector_index: vector.VectorIndex,
    snapshot_manager: snapshot.SnapshotManager,
    
    // Persistent indexes for instant startup
    persistent_index_manager: persistent_index.PersistentIndexManager,
    
    // Query engines
    graph_traversal: graph.GraphTraversal,
    vector_search: vector.VectorSearch,
    
    // Monitoring and metrics
    metrics: monitoring.MetricsCollector,
    
    // Optional S3 sync
    s3_sync: ?s3.S3SnapshotSync,
    
    // Configuration
    config: MemoraConfig,

    pub fn init(allocator: std.mem.Allocator, config: MemoraConfig, global_config: ?config_mod.Config) !Memora {
        // Initialize append log
        const log_path = try std.fs.path.join(allocator, &[_][]const u8{ config.data_path, "memora.log" });
        defer allocator.free(log_path);
        
        const append_log = try log_local.AppendLog.init(allocator, log_path, global_config);
        
        // Initialize indexes
        const graph_index = graph_local.GraphIndex.init(allocator);
        const vector_index = vector_local.VectorIndex.init(allocator);
        
        // Initialize snapshot manager with configuration
        const snapshot_config = if (global_config) |global_cfg| 
            snapshot_local.SnapshotConfig.fromConfig(global_cfg) 
        else 
            null;
        const snapshot_manager = try snapshot_local.SnapshotManager.init(allocator, config.data_path, snapshot_config);
        
        // Initialize persistent index manager
        const persistent_config = if (global_config) |global_cfg| 
            persistent_index_local.PersistentIndexConfig.fromConfig(global_cfg) 
        else 
            null;
        const persistent_index_manager = try persistent_index_local.PersistentIndexManager.init(allocator, config.data_path, persistent_config);
        
        // Initialize query engines with configuration
        const graph_config = if (global_config) |global_cfg| 
            graph_local.GraphConfig.fromConfig(global_cfg) 
        else 
            null;
        const graph_traversal = graph_local.GraphTraversal.init(allocator, graph_config);
        
        // Configure vector search with global config if provided
        const vector_config = if (global_config) |global_cfg| 
            vector_local.VectorConfig.fromConfig(global_cfg) 
        else 
            null;
        const vector_search = vector_local.VectorSearch.init(allocator, vector_config);
        
        // Configure monitoring with global config if provided
        const monitoring_config = if (global_config) |global_cfg| 
            monitoring.MonitoringConfig.fromConfig(global_cfg) 
        else 
            null;
        const metrics = try monitoring.MetricsCollector.init(allocator, monitoring_config);
        
        // Initialize S3 sync if configured
        const s3_sync = if (config.s3_bucket) |bucket| 
            s3_local.S3SnapshotSync.init(allocator, bucket, config.s3_region orelse "us-east-1")
        else 
            null;

        var db = Memora{
            .allocator = allocator,
            .append_log = append_log,
            .graph_index = graph_index,
            .vector_index = vector_index,
            .snapshot_manager = snapshot_manager,
            .persistent_index_manager = persistent_index_manager,
            .graph_traversal = graph_traversal,
            .vector_search = vector_search,
            .metrics = metrics,
            .s3_sync = s3_sync,
            .config = config,
        };

        // Load from storage with persistent index fast path
        try db.loadFromStorageWithPersistentIndexes();

        return db;
    }

    pub fn deinit(self: *Memora) void {
        self.append_log.deinit();
        self.graph_index.deinit();
        self.vector_index.deinit();
        self.snapshot_manager.deinit();
        self.persistent_index_manager.deinit();
        self.metrics.deinit();
    }

    /// Insert a node into the database
    pub fn insertNode(self: *Memora, node: types.Node) !void {
        const start_time = std.time.nanoTimestamp();
        
        // Write to log first (write-ahead logging)
        const log_entry = types.LogEntry.initNode(node);
        self.append_log.append(log_entry) catch |err| {
            self.metrics.recordInsertError();
            return err;
        };
        
        // Update in-memory index
        self.graph_index.addNode(node) catch |err| {
            self.metrics.recordInsertError();
            return err;
        };
        
        // Record metrics
        const duration_us = @divTrunc(std.time.nanoTimestamp() - start_time, 1000);
        self.metrics.recordNodeInsert(@intCast(duration_us));
        
        // Auto-snapshot if configured
        self.autoSnapshot() catch |err| {
            self.metrics.recordSystemError();
            return err;
        };
    }

    /// Insert an edge into the database
    pub fn insertEdge(self: *Memora, edge: types.Edge) !void {
        const start_time = std.time.nanoTimestamp();
        
        // Write to log first
        const log_entry = types.LogEntry.initEdge(edge);
        self.append_log.append(log_entry) catch |err| {
            self.metrics.recordInsertError();
            return err;
        };
        
        // Update in-memory index
        self.graph_index.addEdge(edge) catch |err| {
            self.metrics.recordInsertError();
            return err;
        };
        
        // Record metrics
        const duration_us = @divTrunc(std.time.nanoTimestamp() - start_time, 1000);
        self.metrics.recordEdgeInsert(@intCast(duration_us));
        
        // Auto-snapshot if configured
        self.autoSnapshot() catch |err| {
            self.metrics.recordSystemError();
            return err;
        };
    }

    /// Insert a vector into the database
    pub fn insertVector(self: *Memora, vec: types.Vector) !void {
        const start_time = std.time.nanoTimestamp();
        
        // Write to log first
        const log_entry = types.LogEntry.initVector(vec);
        self.append_log.append(log_entry) catch |err| {
            self.metrics.recordInsertError();
            return err;
        };
        
        // Update in-memory index
        self.vector_index.addVector(vec) catch |err| {
            self.metrics.recordInsertError();
            return err;
        };
        
        // Record metrics
        const duration_us = @divTrunc(std.time.nanoTimestamp() - start_time, 1000);
        self.metrics.recordVectorInsert(@intCast(duration_us));
        
        // Auto-snapshot if configured
        self.autoSnapshot() catch |err| {
            self.metrics.recordSystemError();
            return err;
        };
    }

    /// Batch insert multiple items efficiently
    pub fn insertBatch(self: *Memora, nodes: []const types.Node, edges: []const types.Edge, vectors: []const types.Vector) !void {
        var batch_writer = log.BatchWriter.init(self.allocator, 1000);
        defer batch_writer.deinit();

        // Add all items to batch
        for (nodes) |node| {
            try batch_writer.addNode(node);
            try self.graph_index.addNode(node);
        }

        for (edges) |edge| {
            try batch_writer.addEdge(edge);
            try self.graph_index.addEdge(edge);
        }

        for (vectors) |vec| {
            try batch_writer.addVector(vec);
            try self.vector_index.addVector(vec);
        }

        // Flush batch to log
        try batch_writer.flush(&self.append_log);
        
        // Auto-snapshot if configured
        try self.autoSnapshot();
    }

    /// Query similar vectors using vector search
    pub fn querySimilar(self: *Memora, vector_id: u64, top_k: u32) !std.ArrayList(types.SimilarityResult) {
        const start_time = std.time.nanoTimestamp();
        
        const result = self.vector_search.querySimilar(&self.vector_index, vector_id, top_k) catch |err| {
            self.metrics.recordQueryError();
            return err;
        };
        
        // Record metrics
        const duration_us = @divTrunc(std.time.nanoTimestamp() - start_time, 1000);
        self.metrics.recordSimilarityQuery(@intCast(duration_us));
        
        return result;
    }

    /// Query related nodes using graph traversal
    pub fn queryRelated(self: *Memora, start_node_id: u64, depth: u8) !std.ArrayList(types.Node) {
        const start_time = std.time.nanoTimestamp();
        
        const result = self.graph_traversal.queryRelated(&self.graph_index, start_node_id, @as(?u8, depth)) catch |err| {
            self.metrics.recordQueryError();
            return err;
        };
        
        // Record metrics
        const duration_us = @divTrunc(std.time.nanoTimestamp() - start_time, 1000);
        self.metrics.recordGraphQuery(@intCast(duration_us));
        
        return result;
    }

    /// Advanced query: find vectors similar to nodes connected to a given node
    pub fn queryHybrid(self: *Memora, start_node_id: u64, depth: u8, top_k: u32) !HybridQueryResult {
        const start_time = std.time.nanoTimestamp();
        
        // First, find related nodes
        const related_nodes = self.queryRelated(start_node_id, depth) catch |err| {
            self.metrics.recordQueryError();
            return err;
        };
        defer related_nodes.deinit();

        var similar_vectors = std.ArrayList(types.SimilarityResult).init(self.allocator);
        var node_vector_map = std.AutoHashMap(u64, u64).init(self.allocator);
        defer node_vector_map.deinit();

        // Find vectors for each related node (assuming node_id == vector_id for simplicity)
        for (related_nodes.items) |node| {
            if (self.vector_index.getVector(node.id)) |_| {
                const node_similar = self.vector_search.querySimilar(&self.vector_index, node.id, top_k) catch |err| {
                    self.metrics.recordQueryError();
                    return err;
                };
                defer node_similar.deinit();
                
                similar_vectors.appendSlice(node_similar.items) catch |err| {
                    self.metrics.recordQueryError();
                    return err;
                };
                node_vector_map.put(node.id, node.id) catch |err| {
                    self.metrics.recordQueryError();
                    return err;
                };
            }
        }

        // Sort by similarity (descending)
        std.mem.sort(types.SimilarityResult, similar_vectors.items, {}, compareByDescendingSimilarity);

        // Limit results to top_k
        if (similar_vectors.items.len > top_k) {
            similar_vectors.shrinkRetainingCapacity(top_k);
        }

        // Clone the related nodes to return
        var cloned_related_nodes = std.ArrayList(types.Node).init(self.allocator);
        cloned_related_nodes.appendSlice(related_nodes.items) catch |err| {
            self.metrics.recordQueryError();
            return err;
        };

        // Clone the node_vector_map to return
        var cloned_node_vector_map = std.AutoHashMap(u64, u64).init(self.allocator);
        var map_iter = node_vector_map.iterator();
        while (map_iter.next()) |entry| {
            cloned_node_vector_map.put(entry.key_ptr.*, entry.value_ptr.*) catch |err| {
                self.metrics.recordQueryError();
                return err;
            };
        }

        const result = HybridQueryResult{
            .related_nodes = cloned_related_nodes,
            .similar_vectors = similar_vectors,
            .node_vector_map = cloned_node_vector_map,
        };
        
        // Record metrics
        const duration_us = @divTrunc(std.time.nanoTimestamp() - start_time, 1000);
        self.metrics.recordHybridQuery(@intCast(duration_us));
        
        return result;
    }

    /// Create a snapshot manually
    pub fn createSnapshot(self: *Memora) !snapshot.SnapshotInfo {
        // Sync log to disk first
        try self.append_log.sync();

        // Extract current data
        const vectors = try self.getAllVectors();
        defer vectors.deinit();
        
        const nodes = try self.getAllNodes();
        defer nodes.deinit();
        
        const edges = try self.getAllEdges();
        defer edges.deinit();
        
        const memory_contents = try self.getAllMemoryContent();
        defer {
            // Free the allocated content strings
            for (memory_contents.items) |memory_content| {
                self.allocator.free(memory_content.content);
            }
            memory_contents.deinit();
        }

        // Create snapshot with memory contents included
        const snapshot_info = try self.snapshot_manager.createSnapshot(vectors.items, nodes.items, edges.items, memory_contents.items);

        // Now we can safely clear the append log since memory content is preserved in snapshot files
        try self.append_log.clear();

        // Upload to S3 if configured
        if (self.s3_sync) |*s3_client| {
            if (self.config.s3_prefix) |prefix| {
                try s3_client.uploadSnapshot(self.config.data_path, snapshot_info.snapshot_id, prefix);
            }
        }

        return snapshot_info;
    }

    /// Load from S3 if available, otherwise from local snapshots
    pub fn loadFromStorage(self: *Memora) !void {
        // Try to load from S3 first if configured
        if (self.s3_sync) |*s3_client| {
            if (self.config.s3_prefix) |prefix| {
                self.loadFromS3(s3_client, prefix) catch {
                    std.debug.print("Failed to load from S3, falling back to local\n", .{});
                };
            }
        }

        // Try to load from local snapshot
        if (try self.snapshot_manager.loadLatestSnapshot()) |snapshot_info| {
            defer snapshot_info.deinit();
            try self.loadFromSnapshot(&snapshot_info);
        }
        
        // Always replay from log to ensure we get any entries after the snapshot
        // The indexes should handle duplicate entries gracefully
        try self.replayFromLog();
    }

    /// Get database statistics
    pub fn getStats(self: *Memora) types.DatabaseStats {
        const snapshot_count = if (self.snapshot_manager.listSnapshots()) |snapshots| blk: {
            defer snapshots.deinit();
            break :blk snapshots.items.len;
        } else |_| 0;
        
        const uptime = std.time.timestamp() - self.metrics.startup_timestamp;
        
        const stats = types.DatabaseStats{
            .node_count = self.graph_index.getNodeCount(),
            .edge_count = self.graph_index.getEdgeCount(),
            .vector_count = self.vector_index.getVectorCount(),
            .log_entry_count = self.append_log.getEntryCount(),
            .snapshot_count = @intCast(snapshot_count),
            .memory_usage = @intCast(@max(0, self.metrics.memory_usage_bytes.get())),
            .disk_usage = 0, // TODO: Calculate actual disk usage
            .uptime_seconds = @intCast(@max(0, uptime)),
        };
        
        // Update metrics collector
        self.metrics.updateDatabaseStats(stats);
        
        return stats;
    }

    /// Cleanup old data (snapshots and logs)
    pub fn cleanup(self: *Memora, keep_snapshots: u32) !CleanupResult {
        var result = CleanupResult{ .deleted_snapshots = 0, .deleted_s3_snapshots = 0 };

        // Clean up local snapshots
        result.deleted_snapshots = try self.snapshot_manager.cleanup(keep_snapshots);

        // Clean up S3 snapshots if configured
        if (self.s3_sync) |*s3_client| {
            if (self.config.s3_prefix) |prefix| {
                result.deleted_s3_snapshots = try s3_client.cleanupRemoteSnapshots(prefix, keep_snapshots);
            }
        }

        return result;
    }

    /// Compact the append log by keeping only recent entries
    /// This significantly reduces log file size by removing old entries
    /// Returns the number of entries removed
    pub fn compactLog(self: *Memora, keep_recent_count: u64) !u64 {
        const start_time = std.time.nanoTimestamp();
        
        // Create a snapshot first to preserve all data
        var snapshot_info = try self.createSnapshot();
        defer snapshot_info.deinit();
        
        // Compact the log - this will clear the log and rebuild indexes from the snapshot
        const entries_removed = try self.append_log.compactLog(keep_recent_count);
        
        // Record metrics
        const duration_us = @divTrunc(std.time.nanoTimestamp() - start_time, 1000);
        self.metrics.recordLogCompaction(@intCast(duration_us), entries_removed);
        
        return entries_removed;
    }

    // Private methods

    fn autoSnapshot(self: *Memora) !void {
        // Use the snapshot manager's configuration for auto interval
        if (self.snapshot_manager.config.auto_interval > 0) {
            const current_entries = self.append_log.getEntryCount();
            if (current_entries > 0 and current_entries % self.snapshot_manager.config.auto_interval == 0) {
                var snapshot_info = try self.createSnapshot();
                defer snapshot_info.deinit();
                
                // Auto cleanup if enabled
                if (self.snapshot_manager.config.cleanup_auto_enable) {
                    _ = try self.snapshot_manager.cleanup(self.snapshot_manager.config.cleanup_keep_count);
                }
            }
        }
    }

    fn loadFromS3(self: *Memora, s3_client: *s3.S3SnapshotSync, prefix: []const u8) !void {
        const remote_snapshots = try s3_client.listRemoteSnapshots(prefix);
        defer remote_snapshots.deinit();

        if (remote_snapshots.items.len > 0) {
            const latest_snapshot_id = remote_snapshots.items[remote_snapshots.items.len - 1];
            try s3_client.downloadSnapshot(prefix, latest_snapshot_id, self.config.data_path);
            
            // Load the downloaded snapshot
            if (try self.snapshot_manager.loadSnapshot(latest_snapshot_id)) |snapshot_info| {
                defer snapshot_info.deinit();
                try self.loadFromSnapshot(&snapshot_info);
            }
        }
    }

    fn loadFromSnapshot(self: *Memora, snapshot_info: *const snapshot.SnapshotInfo) !void {
        // Clear existing indexes
        self.graph_index.deinit();
        self.vector_index.deinit();
        
        self.graph_index = graph.GraphIndex.init(self.allocator);
        self.vector_index = vector.VectorIndex.init(self.allocator);

        // Load vectors
        const vectors = try self.snapshot_manager.loadVectors(snapshot_info);
        defer vectors.deinit();
        for (vectors.items) |vec| {
            try self.vector_index.addVector(vec);
        }

        // Load nodes
        const nodes = try self.snapshot_manager.loadNodes(snapshot_info);
        defer nodes.deinit();
        for (nodes.items) |node| {
            try self.graph_index.addNode(node);
        }

        // Load edges
        const edges = try self.snapshot_manager.loadEdges(snapshot_info);
        defer edges.deinit();
        for (edges.items) |edge| {
            try self.graph_index.addEdge(edge);
        }

        // Note: Memory contents are handled separately by MemoryManager
        // when it calls loadMemoryContentsFromSnapshot during its initialization
    }

    fn replayFromLog(self: *Memora) !void {
        var iter = self.append_log.iterator();
        
        while (iter.next()) |entry| {
            switch (entry.getEntryType()) {
                .node => {
                    if (entry.asNode()) |node| {
                        try self.graph_index.addNode(node);
                    }
                },
                .edge => {
                    if (entry.asEdge()) |edge| {
                        try self.graph_index.addEdge(edge);
                    }
                },
                .vector => {
                    if (entry.asVector()) |vec| {
                        try self.vector_index.addVector(vec);
                    }
                },
                .memory_content => {
                    // Memory content entries are handled by MemoryManager during initialization
                    // We don't need to do anything here since content will be loaded on-demand
                },
            }
        }
    }

    pub fn getAllVectors(self: *Memora) !std.ArrayList(types.Vector) {
        var vectors = std.ArrayList(types.Vector).init(self.allocator);
        
        for (self.vector_index.vector_list.items) |vec| {
            try vectors.append(vec);
        }
        
        return vectors;
    }

    pub fn getAllNodes(self: *Memora) !std.ArrayList(types.Node) {
        var nodes = std.ArrayList(types.Node).init(self.allocator);
        
        var iter = self.graph_index.nodes.iterator();
        while (iter.next()) |entry| {
            try nodes.append(entry.value_ptr.*);
        }
        
        return nodes;
    }

    /// Get all edges from the database
    pub fn getAllEdges(self: *Memora) !std.ArrayList(types.Edge) {
        var edges = std.ArrayList(types.Edge).init(self.allocator);
        
        var iter = self.graph_index.outgoing_edges.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.items) |edge| {
                try edges.append(edge);
            }
        }
        
        return edges;
    }

    /// Get all memory content from the MemoryManager's cache for snapshot creation
    pub fn getAllMemoryContentFromManager(self: *Memora, mem_manager: *memory_manager.MemoryManager) !std.ArrayList(types.MemoryContent) {
        var memory_contents = std.ArrayList(types.MemoryContent).init(self.allocator);
        
        // Get memory content from MemoryManager's in-memory cache
        var content_iter = mem_manager.memory_content.iterator();
        while (content_iter.next()) |entry| {
            const memory_id = entry.key_ptr.*;
            const content = entry.value_ptr.*;
            
            // Allocate a copy of the content for the snapshot
            const content_copy = try self.allocator.dupe(u8, content);
            const memory_content = types.MemoryContent{
                .memory_id = memory_id,
                .content = content_copy,
            };
            try memory_contents.append(memory_content);
        }
        
        return memory_contents;
    }

    /// Get all memory content from the MemoryManager's cache (not just the log)
    pub fn getAllMemoryContent(self: *Memora) !std.ArrayList(types.MemoryContent) {
        var memory_contents = std.ArrayList(types.MemoryContent).init(self.allocator);
        
        // This is a fallback method when MemoryManager is not available
        // Get from log as backup
        var iter = self.append_log.iterator();
        while (iter.next()) |entry| {
            if (entry.getEntryType() == .memory_content) {
                if (entry.asMemoryContent()) |mem_content| {
                    // Allocate a copy of the content for the snapshot
                    const content_copy = try self.allocator.dupe(u8, mem_content.content);
                    const memory_content = types.MemoryContent{
                        .memory_id = mem_content.memory_id,
                        .content = content_copy,
                    };
                    try memory_contents.append(memory_content);
                }
            }
        }
        
        return memory_contents;
    }

    /// Load data from storage with persistent index fast path
    fn loadFromStorageWithPersistentIndexes(self: *Memora) !void {
        if (!self.persistent_index_manager.isEnabled()) {
            // Fall back to normal loading if persistent indexes disabled
            return self.loadFromStorage();
        }
        
        // Try to load from persistent indexes first (instant startup)
        if (self.persistent_index_manager.indexesExist()) {
            const start_time = std.time.nanoTimestamp();
            
            const persistent_data = self.persistent_index_manager.loadIndexes() catch |err| {
                if (self.persistent_index_manager.config.auto_rebuild) {
                    std.debug.print("Failed to load persistent indexes ({}), rebuilding from log...\n", .{err});
                    try self.loadFromStorage();
                    return self.savePersistentIndexes();
                } else {
                    return err;
                }
            };
            
            // Load persistent data into in-memory indexes
            try self.loadFromPersistentData(persistent_data);
            
            const load_time = std.time.nanoTimestamp() - start_time;
            std.debug.print("Loaded from persistent indexes in {}µs\n", .{@divTrunc(load_time, 1000)});
            
            // Replay any new log entries since last index save
            try self.replayLogSinceLastIndexSave();
        } else {
            // No persistent indexes exist, do normal startup and save indexes
            std.debug.print("No persistent indexes found, loading from log...\n", .{});
            try self.loadFromStorage();
            try self.savePersistentIndexes();
        }
    }
    
    /// Load persistent data into in-memory indexes
    fn loadFromPersistentData(self: *Memora, persistent_data: anytype) !void {
        // Load nodes
        for (persistent_data.nodes) |node| {
            try self.graph_index.addNode(node);
        }
        
        // Load edges
        for (persistent_data.edges) |edge| {
            try self.graph_index.addEdge(edge);
        }
        
        // Load vectors
        for (persistent_data.vectors) |vec| {
            try self.vector_index.addVector(vec);
        }
    }
    
    /// Replay log entries that occurred since last persistent index save
    fn replayLogSinceLastIndexSave(self: *Memora) !void {
        // For now, replay all log entries to ensure consistency
        // TODO: Implement timestamp-based log replay for optimization
        try self.replayFromLog();
    }
    
    /// Save current in-memory indexes to persistent storage
    pub fn savePersistentIndexes(self: *Memora) !void {
        if (!self.persistent_index_manager.isEnabled()) return;
        
        const start_time = std.time.nanoTimestamp();
        
        // Extract data from in-memory indexes
        const graph_data = try persistent_index.IndexUtils.graphToArrays(&self.graph_index, self.allocator);
        defer graph_data.nodes.deinit();
        defer graph_data.edges.deinit();
        
        const vector_data = try persistent_index.IndexUtils.vectorsToArray(&self.vector_index, self.allocator);
        defer vector_data.deinit();
        
        // Save to persistent indexes
        try self.persistent_index_manager.saveIndexes(
            graph_data.nodes.items,
            graph_data.edges.items,
            vector_data.items
        );
        
        const save_time = std.time.nanoTimestamp() - start_time;
        std.debug.print("Saved persistent indexes in {}µs\n", .{@divTrunc(save_time, 1000)});
    }
    
    /// Check if persistent indexes should be synced
    fn shouldSyncPersistentIndexes(self: *Memora) bool {
        if (!self.persistent_index_manager.isEnabled()) return false;
        
        if (self.persistent_index_manager.config.sync_interval > 0) {
            // TODO: Track operation count since last sync
            return false; // For now, only manual sync
        }
        
        return false;
    }
};

pub const MemoraConfig = struct {
    data_path: []const u8,
    auto_snapshot_interval: ?u64 = null, // Create snapshot every N log entries
    s3_bucket: ?[]const u8 = null,
    s3_region: ?[]const u8 = null,
    s3_prefix: ?[]const u8 = null,
    
    // Persistent index configuration
    enable_persistent_indexes: bool = true,
    persistent_index_sync_interval: ?u64 = 100, // Sync indexes every N operations
    persistent_index_auto_rebuild: bool = true, // Rebuild from log if indexes are corrupt
};

pub const HybridQueryResult = struct {
    related_nodes: std.ArrayList(types.Node),
    similar_vectors: std.ArrayList(types.SimilarityResult),
    node_vector_map: std.AutoHashMap(u64, u64),

    pub fn deinit(self: *HybridQueryResult) void {
        self.related_nodes.deinit();
        self.similar_vectors.deinit();
        self.node_vector_map.deinit();
    }
};

pub const CleanupResult = struct {
    deleted_snapshots: u32,
    deleted_s3_snapshots: u32,
};

fn compareByDescendingSimilarity(context: void, a: types.SimilarityResult, b: types.SimilarityResult) bool {
    _ = context;
    return a.similarity > b.similarity;
}

/// Demo function showing Memora usage
pub fn demo() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Clean up any existing demo data
    std.fs.cwd().deleteTree("demo_memora") catch {};

    // Configure Memora
    const config = MemoraConfig{
        .data_path = "demo_memora",
        .auto_snapshot_interval = 10, // Snapshot every 10 operations
        .s3_bucket = null, // No S3 for demo
        .s3_region = null,
        .s3_prefix = null,
    };

    // Initialize database
    var db = try Memora.init(allocator, config, null);
    defer db.deinit();
    defer std.fs.cwd().deleteTree("demo_memora") catch {};

    std.debug.print("Memora Demo Started\n", .{});

    // Insert some nodes
    try db.insertNode(types.Node.init(1, "Person"));
    try db.insertNode(types.Node.init(2, "Document"));
    try db.insertNode(types.Node.init(3, "Topic"));
    
    std.debug.print("Inserted nodes\n", .{});

    // Insert some edges
    try db.insertEdge(types.Edge.init(1, 2, types.EdgeKind.owns));
    try db.insertEdge(types.Edge.init(2, 3, types.EdgeKind.related));
    
    std.debug.print("Inserted edges\n", .{});

    // Insert some vectors
    const dims1 = [_]f32{ 1.0, 0.0, 0.0 } ++ [_]f32{0.0} ** 125;
    const dims2 = [_]f32{ 0.9, 0.1, 0.0 } ++ [_]f32{0.0} ** 125;
    const dims3 = [_]f32{ 0.0, 0.0, 1.0 } ++ [_]f32{0.0} ** 125;
    
    try db.insertVector(types.Vector.init(1, &dims1));
    try db.insertVector(types.Vector.init(2, &dims2));
    try db.insertVector(types.Vector.init(3, &dims3));
    
    std.debug.print("Inserted vectors\n", .{});

    // Query similar vectors
    const similar = try db.querySimilar(1, 2);
    defer similar.deinit();
    
    std.debug.print("Found {} similar vectors to vector 1\n", .{similar.items.len});
    for (similar.items) |result| {
        std.debug.print("  Vector {}: similarity = {d:.3}\n", .{ result.id, result.similarity });
    }

    // Query related nodes
    const related = try db.queryRelated(1, 2);
    defer related.deinit();
    
    std.debug.print("Found {} related nodes to node 1 (depth 2)\n", .{related.items.len});
    for (related.items) |node| {
        std.debug.print("  Node {}: {s}\n", .{ node.id, node.getLabelAsString() });
    }

    // Create manual snapshot
    var snapshot_info = try db.createSnapshot();
    defer snapshot_info.deinit();
    
    std.debug.print("Created snapshot {}\n", .{snapshot_info.snapshot_id});

    // Get database stats
    const stats = db.getStats();
    std.debug.print("Database stats:\n", .{});
    std.debug.print("  Nodes: {}\n", .{stats.node_count});
    std.debug.print("  Edges: {}\n", .{stats.edge_count});
    std.debug.print("  Vectors: {}\n", .{stats.vector_count});
    std.debug.print("  Log entries: {}\n", .{stats.log_entry_count});
    std.debug.print("  Snapshots: {}\n", .{stats.snapshot_count});

    std.debug.print("Memora Demo Completed Successfully!\n", .{});
}

pub fn main() !void {
    std.debug.print("Memora - A high-performance context-aware database\\n", .{});
}

test "Memora basic operations" {
    const allocator = std.testing.allocator;
    
    // Clean up any existing test data
    std.fs.cwd().deleteTree("test_memora") catch {};
    
    const config = MemoraConfig{
        .data_path = "test_memora",
        .auto_snapshot_interval = null,
        .s3_bucket = null,
        .s3_region = null,
        .s3_prefix = null,
    };

    var db = try Memora.init(allocator, config, null);
    defer db.deinit();
    defer std.fs.cwd().deleteTree("test_memora") catch {};

    // Test insertions
    try db.insertNode(types.Node.init(1, "TestNode"));
    try db.insertEdge(types.Edge.init(1, 2, types.EdgeKind.owns));
    
    const dims = [_]f32{ 1.0, 0.0, 0.0 } ++ [_]f32{0.0} ** 125;
    try db.insertVector(types.Vector.init(1, &dims));

    // Test queries
    const similar = try db.querySimilar(1, 5);
    defer similar.deinit();
    // Should be empty since we only have one vector
    try std.testing.expect(similar.items.len == 0);

    const related = try db.queryRelated(1, 1);
    defer related.deinit();
    // Should contain the inserted node
    try std.testing.expect(related.items.len >= 1);

    // Test stats
    const stats = db.getStats();
    try std.testing.expect(stats.node_count >= 1);
    try std.testing.expect(stats.edge_count >= 1);
    try std.testing.expect(stats.vector_count >= 1);
} 