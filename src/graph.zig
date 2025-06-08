const std = @import("std");
const types = @import("types.zig");

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

    pub fn init(allocator: std.mem.Allocator) GraphTraversal {
        return GraphTraversal{
            .allocator = allocator,
        };
    }

    /// Breadth-first search traversal with depth limit
    pub fn queryRelated(self: *const GraphTraversal, index: *const GraphIndex, start_node_id: u64, max_depth: u8) !std.ArrayList(types.Node) {
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
            
            if (current.depth > max_depth) continue;

            // Add current node to result
            if (index.getNode(current.node_id)) |node| {
                try result.append(node);
            }

            // Add neighbors to queue if within depth limit
            if (current.depth < max_depth) {
                const neighbors = try index.getNeighbors(current.node_id, self.allocator);
                defer neighbors.deinit();

                for (neighbors.items) |neighbor_id| {
                    if (!visited.contains(neighbor_id)) {
                        try queue.append(.{ .node_id = neighbor_id, .depth = current.depth + 1 });
                        try visited.put(neighbor_id, {});
                    }
                }
            }
        }

        return result;
    }

    /// Find shortest path between two nodes using BFS
    pub fn findShortestPath(self: *const GraphTraversal, index: *const GraphIndex, start_id: u64, end_id: u64) !?std.ArrayList(u64) {
        if (start_id == end_id) {
            var path = std.ArrayList(u64).init(self.allocator);
            try path.append(start_id);
            return path;
        }

        var visited = std.AutoHashMap(u64, void).init(self.allocator);
        defer visited.deinit();

        var parent = std.AutoHashMap(u64, u64).init(self.allocator);
        defer parent.deinit();

        var queue = std.ArrayList(u64).init(self.allocator);
        defer queue.deinit();

        try queue.append(start_id);
        try visited.put(start_id, {});

        while (queue.items.len > 0) {
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

            for (neighbors.items) |neighbor_id| {
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
                    for (edges) |edge| {
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
                    for (edges) |edge| {
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

    const traversal = GraphTraversal.init(allocator);
    
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

    const traversal = GraphTraversal.init(allocator);
    
    // Query only 'owns' relationships
    const owns_related = try traversal.queryByEdgeKind(&graph, 1, types.EdgeKind.owns, .outgoing);
    defer owns_related.deinit();
    
    try std.testing.expect(owns_related.items.len == 1);
    try std.testing.expect(owns_related.items[0].id == 2);
} 