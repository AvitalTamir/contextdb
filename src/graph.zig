const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");

/// In-memory graph index for fast traversal
/// Uses adjacency lists for efficient neighbor queries
pub const GraphIndex = struct {
    allocator: std.mem.Allocator,
    nodes: std.AutoHashMap(u64, types.Node),
    outgoing_edges: std.AutoHashMap(u64, std.ArrayList(types.Edge)),
    incoming_edges: std.AutoHashMap(u64, std.ArrayList(types.Edge)),
    edges_by_kind: std.AutoHashMap(u8, std.ArrayList(types.Edge)),

    pub fn init(allocator: std.mem.Allocator) GraphIndex {
        return GraphIndex{
            .allocator = allocator,
            .nodes = std.AutoHashMap(u64, types.Node).init(allocator),
            .outgoing_edges = std.AutoHashMap(u64, std.ArrayList(types.Edge)).init(allocator),
            .incoming_edges = std.AutoHashMap(u64, std.ArrayList(types.Edge)).init(allocator),
            .edges_by_kind = std.AutoHashMap(u8, std.ArrayList(types.Edge)).init(allocator),
        };
    }

    pub fn deinit(self: *GraphIndex) void {
        // Clean up outgoing edges
        var outgoing_iter = self.outgoing_edges.iterator();
        while (outgoing_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.outgoing_edges.deinit();

        // Clean up incoming edges
        var incoming_iter = self.incoming_edges.iterator();
        while (incoming_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.incoming_edges.deinit();

        // Clean up edges by kind
        var kind_iter = self.edges_by_kind.iterator();
        while (kind_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.edges_by_kind.deinit();

        self.nodes.deinit();
    }

    /// Add a node to the index
    pub fn addNode(self: *GraphIndex, node: types.Node) !void {
        try self.nodes.put(node.id, node);
    }

    /// Add an edge to the index
    pub fn addEdge(self: *GraphIndex, edge: types.Edge) !void {
        // Add to outgoing edges for 'from' node
        var outgoing_result = try self.outgoing_edges.getOrPut(edge.from);
        if (!outgoing_result.found_existing) {
            outgoing_result.value_ptr.* = std.ArrayList(types.Edge).init(self.allocator);
        }
        try outgoing_result.value_ptr.append(edge);

        // Add to incoming edges for 'to' node
        var incoming_result = try self.incoming_edges.getOrPut(edge.to);
        if (!incoming_result.found_existing) {
            incoming_result.value_ptr.* = std.ArrayList(types.Edge).init(self.allocator);
        }
        try incoming_result.value_ptr.append(edge);

        // Add to edges by kind
        var kind_result = try self.edges_by_kind.getOrPut(edge.kind);
        if (!kind_result.found_existing) {
            kind_result.value_ptr.* = std.ArrayList(types.Edge).init(self.allocator);
        }
        try kind_result.value_ptr.append(edge);
    }

    /// Get a node by ID
    pub fn getNode(self: *const GraphIndex, node_id: u64) ?types.Node {
        return self.nodes.get(node_id);
    }

    /// Get outgoing edges for a node
    pub fn getOutgoingEdges(self: *const GraphIndex, node_id: u64) ?[]const types.Edge {
        if (self.outgoing_edges.get(node_id)) |edges| {
            return edges.items;
        }
        return null;
    }

    /// Get incoming edges for a node
    pub fn getIncomingEdges(self: *const GraphIndex, node_id: u64) ?[]const types.Edge {
        if (self.incoming_edges.get(node_id)) |edges| {
            return edges.items;
        }
        return null;
    }

    /// Get all edges of a specific kind
    pub fn getEdgesByKind(self: *const GraphIndex, kind: types.EdgeKind) ?[]const types.Edge {
        if (self.edges_by_kind.get(@intFromEnum(kind))) |edges| {
            return edges.items;
        }
        return null;
    }

    /// Get direct neighbors of a node
    pub fn getNeighbors(self: *const GraphIndex, node_id: u64, allocator: std.mem.Allocator) !std.ArrayList(u64) {
        var neighbors = std.ArrayList(u64).init(allocator);
        var seen = std.AutoHashMap(u64, void).init(allocator);
        defer seen.deinit();

        // Add outgoing neighbors
        if (self.getOutgoingEdges(node_id)) |edges| {
            for (edges) |edge| {
                if (!seen.contains(edge.to)) {
                    try neighbors.append(edge.to);
                    try seen.put(edge.to, {});
                }
            }
        }

        // Add incoming neighbors
        if (self.getIncomingEdges(node_id)) |edges| {
            for (edges) |edge| {
                if (!seen.contains(edge.from)) {
                    try neighbors.append(edge.from);
                    try seen.put(edge.from, {});
                }
            }
        }

        return neighbors;
    }

    /// Count the number of nodes
    pub fn getNodeCount(self: *const GraphIndex) u32 {
        return @intCast(self.nodes.count());
    }

    /// Count the total number of edges
    pub fn getEdgeCount(self: *const GraphIndex) u32 {
        var total: u32 = 0;
        var iter = self.outgoing_edges.iterator();
        while (iter.next()) |entry| {
            total += @intCast(entry.value_ptr.items.len);
        }
        return total;
    }
};

/// Graph traversal engine for complex queries
pub const GraphTraversal = struct {
    allocator: std.mem.Allocator,
    config: GraphConfig,

    pub fn init(allocator: std.mem.Allocator, graph_config: ?GraphConfig) GraphTraversal {
        const cfg = graph_config orelse GraphConfig.fromConfig(config.Config{});
        return GraphTraversal{
            .allocator = allocator,
            .config = cfg,
        };
    }

    /// Breadth-first search traversal with depth limit (uses config default or provided max_depth)
    pub fn queryRelated(self: *const GraphTraversal, index: *const GraphIndex, start_node_id: u64, max_depth: ?u8) !std.ArrayList(types.Node) {
        const actual_max_depth = max_depth orelse self.config.max_traversal_depth;
        var result = std.ArrayList(types.Node).init(self.allocator);
        var visited = std.AutoHashMap(u64, void).init(self.allocator);
        defer visited.deinit();

        var queue = std.ArrayList(struct { node_id: u64, depth: u8 }).init(self.allocator);
        defer queue.deinit();

        // Start with the initial node
        try queue.append(.{ .node_id = start_node_id, .depth = 0 });
        try visited.put(start_node_id, {});

        while (queue.items.len > 0) {
            const current = queue.orderedRemove(0);
            
            if (current.depth > actual_max_depth) continue;

            // Add current node to result
            if (index.getNode(current.node_id)) |node| {
                try result.append(node);
            }

            // Add neighbors to queue if within depth limit and queue size limit
            if (current.depth < actual_max_depth and queue.items.len < self.config.max_queue_size) {
                const neighbors = try index.getNeighbors(current.node_id, self.allocator);
                defer neighbors.deinit();

                // Limit the number of neighbors processed per node
                const max_neighbors = @min(neighbors.items.len, self.config.max_neighbors_per_node);
                for (neighbors.items[0..max_neighbors]) |neighbor_id| {
                    if (!visited.contains(neighbor_id)) {
                        try queue.append(.{ .node_id = neighbor_id, .depth = current.depth + 1 });
                        try visited.put(neighbor_id, {});
                    }
                }
            }
        }

        return result;
    }

    /// Find shortest path between two nodes using BFS (with optional timeout)
    pub fn findShortestPath(self: *const GraphTraversal, index: *const GraphIndex, start_id: u64, end_id: u64) !?std.ArrayList(u64) {
        if (start_id == end_id) {
            var path = std.ArrayList(u64).init(self.allocator);
            try path.append(start_id);
            return path;
        }

        const start_time = std.time.nanoTimestamp();
        const timeout_ns = @as(i64, @intCast(self.config.traversal_timeout_ms)) * 1_000_000; // Convert ms to ns

        var visited = std.AutoHashMap(u64, void).init(self.allocator);
        defer visited.deinit();

        var parent = std.AutoHashMap(u64, u64).init(self.allocator);
        defer parent.deinit();

        var queue = std.ArrayList(u64).init(self.allocator);
        defer queue.deinit();

        try queue.append(start_id);
        try visited.put(start_id, {});

        while (queue.items.len > 0) {
            // Check timeout
            const elapsed_time = std.time.nanoTimestamp() - start_time;
            if (elapsed_time > timeout_ns) {
                return null; // Timeout reached
            }

            // Check queue size limit
            if (queue.items.len > self.config.max_queue_size) {
                return null; // Queue size limit exceeded
            }

            const current_id = queue.orderedRemove(0);
            
            if (current_id == end_id) {
                // Reconstruct path
                var path = std.ArrayList(u64).init(self.allocator);
                var node_id = end_id;
                
                while (true) {
                    try path.insert(0, node_id);
                    if (node_id == start_id) break;
                    node_id = parent.get(node_id).?;
                }
                
                return path;
            }

            const neighbors = try index.getNeighbors(current_id, self.allocator);
            defer neighbors.deinit();

            // Limit the number of neighbors processed per node
            const max_neighbors = @min(neighbors.items.len, self.config.max_neighbors_per_node);
            for (neighbors.items[0..max_neighbors]) |neighbor_id| {
                if (!visited.contains(neighbor_id)) {
                    try visited.put(neighbor_id, {});
                    try parent.put(neighbor_id, current_id);
                    try queue.append(neighbor_id);
                }
            }
        }

        return null; // No path found
    }

    /// Find nodes by specific edge relationship
    pub fn queryByEdgeKind(self: *const GraphTraversal, index: *const GraphIndex, start_node_id: u64, edge_kind: types.EdgeKind, direction: TraversalDirection) !std.ArrayList(types.Node) {
        var result = std.ArrayList(types.Node).init(self.allocator);

        switch (direction) {
            .outgoing => {
                if (index.getOutgoingEdges(start_node_id)) |edges| {
                    const max_edges = @min(edges.len, self.config.max_neighbors_per_node);
                    for (edges[0..max_edges]) |edge| {
                        if (edge.getKind() == edge_kind) {
                            if (index.getNode(edge.to)) |node| {
                                try result.append(node);
                            }
                        }
                    }
                }
            },
            .incoming => {
                if (index.getIncomingEdges(start_node_id)) |edges| {
                    const max_edges = @min(edges.len, self.config.max_neighbors_per_node);
                    for (edges[0..max_edges]) |edge| {
                        if (edge.getKind() == edge_kind) {
                            if (index.getNode(edge.from)) |node| {
                                try result.append(node);
                            }
                        }
                    }
                }
            },
            .both => {
                const outgoing = try self.queryByEdgeKind(index, start_node_id, edge_kind, .outgoing);
                defer outgoing.deinit();
                const incoming = try self.queryByEdgeKind(index, start_node_id, edge_kind, .incoming);
                defer incoming.deinit();
                
                try result.appendSlice(outgoing.items);
                try result.appendSlice(incoming.items);
            },
        }

        return result;
    }

    /// Get node degree (number of connections)
    pub fn getNodeDegree(self: *const GraphTraversal, index: *const GraphIndex, node_id: u64) u32 {
        _ = self; // unused
        var degree: u32 = 0;
        
        if (index.getOutgoingEdges(node_id)) |edges| {
            degree += @intCast(edges.len);
        }
        
        if (index.getIncomingEdges(node_id)) |edges| {
            degree += @intCast(edges.len);
        }
        
        return degree;
    }
};

/// Graph configuration derived from centralized config
pub const GraphConfig = struct {
    max_traversal_depth: u8,
    traversal_timeout_ms: u32,
    max_queue_size: u32,
    max_neighbors_per_node: u32,
    path_cache_size: u32,
    enable_bidirectional_search: bool,
    
    pub fn fromConfig(global_cfg: config.Config) GraphConfig {
        return GraphConfig{
            .max_traversal_depth = global_cfg.graph_max_traversal_depth,
            .traversal_timeout_ms = global_cfg.graph_traversal_timeout_ms,
            .max_queue_size = global_cfg.graph_max_queue_size,
            .max_neighbors_per_node = global_cfg.graph_max_neighbors_per_node,
            .path_cache_size = global_cfg.graph_path_cache_size,
            .enable_bidirectional_search = global_cfg.graph_enable_bidirectional_search,
        };
    }
};

pub const TraversalDirection = enum {
    outgoing,
    incoming,
    both,
};

test "GraphIndex basic operations" {
    const allocator = std.testing.allocator;
    
    var graph = GraphIndex.init(allocator);
    defer graph.deinit();

    // Add nodes
    const node1 = types.Node.init(1, "Node1");
    const node2 = types.Node.init(2, "Node2");
    try graph.addNode(node1);
    try graph.addNode(node2);

    // Add edge
    const edge = types.Edge.init(1, 2, types.EdgeKind.owns);
    try graph.addEdge(edge);

    // Test retrieval
    try std.testing.expect(graph.getNode(1) != null);
    try std.testing.expect(graph.getNodeCount() == 2);
    try std.testing.expect(graph.getEdgeCount() == 1);

    // Test neighbors
    const neighbors = try graph.getNeighbors(1, allocator);
    defer neighbors.deinit();
    try std.testing.expect(neighbors.items.len == 1);
    try std.testing.expect(neighbors.items[0] == 2);
}

test "GraphTraversal BFS" {
    const allocator = std.testing.allocator;
    
    var graph = GraphIndex.init(allocator);
    defer graph.deinit();

    // Create a simple chain: 1 -> 2 -> 3
    try graph.addNode(types.Node.init(1, "Node1"));
    try graph.addNode(types.Node.init(2, "Node2"));
    try graph.addNode(types.Node.init(3, "Node3"));
    
    try graph.addEdge(types.Edge.init(1, 2, types.EdgeKind.owns));
    try graph.addEdge(types.Edge.init(2, 3, types.EdgeKind.owns));

    const traversal = GraphTraversal.init(allocator, null);
    
    // Test related query with depth 2
    const related = try traversal.queryRelated(&graph, 1, 2);
    defer related.deinit();
    
    try std.testing.expect(related.items.len == 3); // Should find all 3 nodes

    // Test shortest path
    const path = (try traversal.findShortestPath(&graph, 1, 3)).?;
    defer path.deinit();
    
    try std.testing.expect(path.items.len == 3);
    try std.testing.expect(path.items[0] == 1);
    try std.testing.expect(path.items[1] == 2);
    try std.testing.expect(path.items[2] == 3);
}

test "GraphTraversal edge kind filtering" {
    const allocator = std.testing.allocator;
    
    var graph = GraphIndex.init(allocator);
    defer graph.deinit();

    // Create nodes
    try graph.addNode(types.Node.init(1, "Node1"));
    try graph.addNode(types.Node.init(2, "Node2"));
    try graph.addNode(types.Node.init(3, "Node3"));
    
    // Add edges with different kinds
    try graph.addEdge(types.Edge.init(1, 2, types.EdgeKind.owns));
    try graph.addEdge(types.Edge.init(1, 3, types.EdgeKind.links));

    const traversal = GraphTraversal.init(allocator, null);
    
    // Query only 'owns' relationships
    const owns_related = try traversal.queryByEdgeKind(&graph, 1, types.EdgeKind.owns, .outgoing);
    defer owns_related.deinit();
    
    try std.testing.expect(owns_related.items.len == 1);
    try std.testing.expect(owns_related.items[0].id == 2);
}

test "Graph configuration integration" {
    const allocator = std.testing.allocator;
    
    // Create custom graph configuration
    const graph_cfg = GraphConfig{
        .max_traversal_depth = 5,
        .traversal_timeout_ms = 1000,
        .max_queue_size = 100,
        .max_neighbors_per_node = 50,
        .path_cache_size = 200,
        .enable_bidirectional_search = false,
    };
    
    // Test GraphTraversal with custom config
    const traversal = GraphTraversal.init(allocator, graph_cfg);
    try std.testing.expect(traversal.config.max_traversal_depth == 5);
    try std.testing.expect(traversal.config.traversal_timeout_ms == 1000);
    try std.testing.expect(traversal.config.max_queue_size == 100);
    try std.testing.expect(traversal.config.max_neighbors_per_node == 50);
    try std.testing.expect(traversal.config.path_cache_size == 200);
    try std.testing.expect(traversal.config.enable_bidirectional_search == false);
    
    // Test default config fallback
    const traversal_default = GraphTraversal.init(allocator, null);
    try std.testing.expect(traversal_default.config.max_traversal_depth == 10);
    try std.testing.expect(traversal_default.config.traversal_timeout_ms == 5000);
    try std.testing.expect(traversal_default.config.max_queue_size == 10000);
    try std.testing.expect(traversal_default.config.max_neighbors_per_node == 1000);
    try std.testing.expect(traversal_default.config.path_cache_size == 1000);
    try std.testing.expect(traversal_default.config.enable_bidirectional_search == true);
}

test "GraphTraversal with depth limits" {
    const allocator = std.testing.allocator;
    
    var graph = GraphIndex.init(allocator);
    defer graph.deinit();

    // Create a chain of nodes: 1 -> 2 -> 3 -> 4 -> 5
    try graph.addNode(types.Node.init(1, "Node1"));
    try graph.addNode(types.Node.init(2, "Node2"));
    try graph.addNode(types.Node.init(3, "Node3"));
    try graph.addNode(types.Node.init(4, "Node4"));
    try graph.addNode(types.Node.init(5, "Node5"));
    
    try graph.addEdge(types.Edge.init(1, 2, types.EdgeKind.owns));
    try graph.addEdge(types.Edge.init(2, 3, types.EdgeKind.owns));
    try graph.addEdge(types.Edge.init(3, 4, types.EdgeKind.owns));
    try graph.addEdge(types.Edge.init(4, 5, types.EdgeKind.owns));

    // Create config with smaller depth limit
    const graph_cfg = GraphConfig{
        .max_traversal_depth = 2,
        .traversal_timeout_ms = 5000,
        .max_queue_size = 1000,
        .max_neighbors_per_node = 100,
        .path_cache_size = 100,
        .enable_bidirectional_search = true,
    };
    
    const traversal = GraphTraversal.init(allocator, graph_cfg);
    
    // Test with no explicit depth (uses config default of 2)
    const related_default = try traversal.queryRelated(&graph, 1, null);
    defer related_default.deinit();
    
    // Should only find nodes 1, 2, 3 (depth 0, 1, 2)
    try std.testing.expect(related_default.items.len == 3);
    
    // Test with explicit depth that overrides config
    const related_explicit = try traversal.queryRelated(&graph, 1, 3);
    defer related_explicit.deinit();
    
    // Should find nodes 1, 2, 3, 4 (depth 0, 1, 2, 3)
    try std.testing.expect(related_explicit.items.len == 4);
}

test "GraphTraversal with neighbor limits" {
    const allocator = std.testing.allocator;
    
    var graph = GraphIndex.init(allocator);
    defer graph.deinit();

    // Create a central node with many connections
    try graph.addNode(types.Node.init(1, "Central"));
    
    // Add many connected nodes
    for (2..12) |i| {
        const node_id: u64 = @intCast(i);
        const label = try std.fmt.allocPrint(allocator, "Node{}", .{i});
        defer allocator.free(label);
        try graph.addNode(types.Node.init(node_id, label));
        try graph.addEdge(types.Edge.init(1, node_id, types.EdgeKind.owns));
    }

    // Create config with neighbor limit
    const graph_cfg = GraphConfig{
        .max_traversal_depth = 2,
        .traversal_timeout_ms = 5000,
        .max_queue_size = 1000,
        .max_neighbors_per_node = 5, // Limit to 5 neighbors
        .path_cache_size = 100,
        .enable_bidirectional_search = true,
    };
    
    const traversal = GraphTraversal.init(allocator, graph_cfg);
    
    // Test with neighbor limit
    const related = try traversal.queryRelated(&graph, 1, 1);
    defer related.deinit();
    
    // Should find central node + at most 5 neighbors (6 total)
    try std.testing.expect(related.items.len <= 6);
}

test "Graph configuration integration with global config" {
    const allocator = std.testing.allocator;
    
    // Create a global configuration with custom graph settings
    const global_cfg = config.Config{
        .graph_max_traversal_depth = 8,
        .graph_traversal_timeout_ms = 2000,
        .graph_max_queue_size = 5000,
        .graph_max_neighbors_per_node = 500,
        .graph_path_cache_size = 800,
        .graph_enable_bidirectional_search = false,
    };
    
    // Test GraphConfig.fromConfig
    const graph_cfg = GraphConfig.fromConfig(global_cfg);
    try std.testing.expect(graph_cfg.max_traversal_depth == 8);
    try std.testing.expect(graph_cfg.traversal_timeout_ms == 2000);
    try std.testing.expect(graph_cfg.max_queue_size == 5000);
    try std.testing.expect(graph_cfg.max_neighbors_per_node == 500);
    try std.testing.expect(graph_cfg.path_cache_size == 800);
    try std.testing.expect(graph_cfg.enable_bidirectional_search == false);
    
    // Test GraphTraversal with global config
    const traversal = GraphTraversal.init(allocator, graph_cfg);
    try std.testing.expect(traversal.config.max_traversal_depth == 8);
    try std.testing.expect(traversal.config.traversal_timeout_ms == 2000);
    try std.testing.expect(traversal.config.max_queue_size == 5000);
    try std.testing.expect(traversal.config.max_neighbors_per_node == 500);
    try std.testing.expect(traversal.config.path_cache_size == 800);
    try std.testing.expect(traversal.config.enable_bidirectional_search == false);
    
    std.debug.print("✓ Graph configuration integration test passed\n", .{});
}

test "End-to-end graph configuration demonstration" {
    const allocator = std.testing.allocator;
    
    // Simulate configuration loading from file
    const config_content =
        \\# Graph configuration test
        \\graph_max_traversal_depth = 3
        \\graph_traversal_timeout_ms = 1000
        \\graph_max_queue_size = 500
        \\graph_max_neighbors_per_node = 10
        \\graph_path_cache_size = 100
        \\graph_enable_bidirectional_search = false
    ;
    
    // Parse configuration
    const global_cfg = try config.Config.parseFromString(config_content);
    
    // Create graph configuration from global config
    const graph_cfg = GraphConfig.fromConfig(global_cfg);
    
    // Create graph and traversal with config
    var graph = GraphIndex.init(allocator);
    defer graph.deinit();
    
    const traversal = GraphTraversal.init(allocator, graph_cfg);
    
    // Create test data
    try graph.addNode(types.Node.init(1, "Start"));
    try graph.addNode(types.Node.init(2, "Middle1"));
    try graph.addNode(types.Node.init(3, "Middle2"));
    try graph.addNode(types.Node.init(4, "End"));
    try graph.addNode(types.Node.init(5, "TooFar"));
    
    try graph.addEdge(types.Edge.init(1, 2, types.EdgeKind.owns));
    try graph.addEdge(types.Edge.init(2, 3, types.EdgeKind.owns));
    try graph.addEdge(types.Edge.init(3, 4, types.EdgeKind.owns));
    try graph.addEdge(types.Edge.init(4, 5, types.EdgeKind.owns));
    
    // Test traversal respects configured depth limit (3)
    const related = try traversal.queryRelated(&graph, 1, null);
    defer related.deinit();
    
    // Should find nodes 1, 2, 3, 4 (depths 0, 1, 2, 3) but not 5 (depth 4)
    try std.testing.expect(related.items.len == 4);
    
    // Verify configuration is working
    try std.testing.expect(traversal.config.max_traversal_depth == 3);
    try std.testing.expect(traversal.config.max_neighbors_per_node == 10);
    
    std.debug.print("✓ End-to-end graph configuration test passed\n", .{});
} 