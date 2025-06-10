const std = @import("std");

/// Core data types for Memora
pub const Node = struct {
    id: u64,
    label: [32]u8,

    pub fn init(id: u64, label: []const u8) Node {
        var label_array = [_]u8{0} ** 32;
        const copy_len = @min(label.len, 32);
        @memcpy(label_array[0..copy_len], label[0..copy_len]);
        return Node{ .id = id, .label = label_array };
    }

    pub fn getLabelAsString(self: *const Node) []const u8 {
        var end: usize = 0;
        for (self.label) |byte| {
            if (byte == 0) break;
            end += 1;
        }
        return self.label[0..end];
    }
};

pub const EdgeKind = enum(u8) {
    owns = 0,
    links = 1,
    related = 2,
    child_of = 3,
    similar_to = 4,
    _,
};

pub const Edge = packed struct {
    from: u64,
    to: u64,
    kind: u8,

    pub fn init(from: u64, to: u64, kind: EdgeKind) Edge {
        return Edge{
            .from = from,
            .to = to,
            .kind = @intFromEnum(kind),
        };
    }

    pub fn getKind(self: *const Edge) EdgeKind {
        return @enumFromInt(self.kind);
    }
};

/// Vector for similarity search
/// Fixed 128-dimensional vectors for simplicity
pub const Vector = struct {
    id: u64,
    dims: [128]f32,

    pub fn init(id: u64, dims: []const f32) Vector {
        var dims_array = [_]f32{0.0} ** 128;
        const copy_len = @min(dims.len, 128);
        @memcpy(dims_array[0..copy_len], dims[0..copy_len]);
        return Vector{ .id = id, .dims = dims_array };
    }

    pub fn dotProduct(self: *const Vector, other: *const Vector) f32 {
        var sum: f32 = 0.0;
        for (self.dims, other.dims) |a, b| {
            sum += a * b;
        }
        return sum;
    }

    pub fn magnitude(self: *const Vector) f32 {
        var sum: f32 = 0.0;
        for (self.dims) |dim| {
            sum += dim * dim;
        }
        return @sqrt(sum);
    }

    pub fn cosineSimilarity(self: *const Vector, other: *const Vector) f32 {
        const dot = self.dotProduct(other);
        const mag_a = self.magnitude();
        const mag_b = other.magnitude();
        if (mag_a == 0.0 or mag_b == 0.0) return 0.0;
        return dot / (mag_a * mag_b);
    }
};

/// Query result types
pub const SimilarityResult = struct {
    id: u64,
    similarity: f32,
};

pub const GraphResult = struct {
    nodes: std.ArrayList(Node),
    edges: std.ArrayList(Edge),

    pub fn init(allocator: std.mem.Allocator) GraphResult {
        return GraphResult{
            .nodes = std.ArrayList(Node).init(allocator),
            .edges = std.ArrayList(Edge).init(allocator),
        };
    }

    pub fn deinit(self: *GraphResult) void {
        self.nodes.deinit();
        self.edges.deinit();
    }
};

/// Log entry types for append-only storage
pub const LogEntryType = enum(u8) {
    node = 0,
    edge = 1,
    vector = 2,
};

pub const LogEntry = struct {
    entry_type: u8,
    timestamp: u64,
    data: [520]u8, // Max size to fit Vector (8 + 128*4 = 520 bytes)

    pub fn initNode(node: Node) LogEntry {
        var entry = LogEntry{
            .entry_type = @intFromEnum(LogEntryType.node),
            .timestamp = @intCast(std.time.timestamp()),
            .data = [_]u8{0} ** 520,
        };
        const node_bytes = std.mem.asBytes(&node);
        @memcpy(entry.data[0..node_bytes.len], node_bytes);
        return entry;
    }

    pub fn initEdge(edge: Edge) LogEntry {
        var entry = LogEntry{
            .entry_type = @intFromEnum(LogEntryType.edge),
            .timestamp = @intCast(std.time.timestamp()),
            .data = [_]u8{0} ** 520,
        };
        const edge_bytes = std.mem.asBytes(&edge);
        @memcpy(entry.data[0..edge_bytes.len], edge_bytes);
        return entry;
    }

    pub fn initVector(vector: Vector) LogEntry {
        var entry = LogEntry{
            .entry_type = @intFromEnum(LogEntryType.vector),
            .timestamp = @intCast(std.time.timestamp()),
            .data = [_]u8{0} ** 520,
        };
        const vector_bytes = std.mem.asBytes(&vector);
        @memcpy(entry.data[0..vector_bytes.len], vector_bytes);
        return entry;
    }

    pub fn getEntryType(self: *const LogEntry) LogEntryType {
        return @enumFromInt(self.entry_type);
    }

    pub fn asNode(self: *const LogEntry) ?Node {
        if (self.getEntryType() != .node) return null;
        const node = std.mem.bytesToValue(Node, self.data[0..@sizeOf(Node)]);
        // Reject nodes with ID 0 as they are likely corrupted
        if (node.id == 0) return null;
        return node;
    }

    pub fn asEdge(self: *const LogEntry) ?Edge {
        if (self.getEntryType() != .edge) return null;
        return std.mem.bytesToValue(Edge, self.data[0..@sizeOf(Edge)]);
    }

    pub fn asVector(self: *const LogEntry) ?Vector {
        if (self.getEntryType() != .vector) return null;
        return std.mem.bytesToValue(Vector, self.data[0..@sizeOf(Vector)]);
    }
};

/// Snapshot metadata
pub const SnapshotMetadata = struct {
    snapshot_id: u64,
    timestamp: []const u8,
    vector_files: std.ArrayList([]const u8),
    node_files: std.ArrayList([]const u8),
    edge_files: std.ArrayList([]const u8),
    counts: struct {
        vectors: u64,
        nodes: u64,
        edges: u64,
    },

    pub fn init(allocator: std.mem.Allocator, snapshot_id: u64) SnapshotMetadata {
        return SnapshotMetadata{
            .snapshot_id = snapshot_id,
            .timestamp = "",
            .vector_files = std.ArrayList([]const u8).init(allocator),
            .node_files = std.ArrayList([]const u8).init(allocator),
            .edge_files = std.ArrayList([]const u8).init(allocator),
            .counts = .{ .vectors = 0, .nodes = 0, .edges = 0 },
        };
    }

    pub fn deinit(self: *SnapshotMetadata) void {
        self.vector_files.deinit();
        self.node_files.deinit();
        self.edge_files.deinit();
    }
};

/// Database statistics for monitoring
pub const DatabaseStats = struct {
    node_count: u64,
    edge_count: u64,
    vector_count: u64,
    log_entry_count: u64,
    snapshot_count: u64,
    memory_usage: u64,
    disk_usage: u64,
    uptime_seconds: u64,
    
    pub fn init() DatabaseStats {
        return DatabaseStats{
            .node_count = 0,
            .edge_count = 0,
            .vector_count = 0,
            .log_entry_count = 0,
            .snapshot_count = 0,
            .memory_usage = 0,
            .disk_usage = 0,
            .uptime_seconds = 0,
        };
    }
};

test "Node creation and label handling" {
    const node = Node.init(1, "TestNode");
    try std.testing.expect(node.id == 1);
    try std.testing.expectEqualStrings("TestNode", node.getLabelAsString());
}

test "Edge creation and kind handling" {
    const edge = Edge.init(1, 2, EdgeKind.owns);
    try std.testing.expect(edge.from == 1);
    try std.testing.expect(edge.to == 2);
    try std.testing.expect(edge.getKind() == EdgeKind.owns);
}

test "Vector operations" {
    const dims1 = [_]f32{ 1.0, 0.0, 0.0 } ++ [_]f32{0.0} ** 125;
    const dims2 = [_]f32{ 0.0, 1.0, 0.0 } ++ [_]f32{0.0} ** 125;
    const vec1 = Vector.init(1, &dims1);
    const vec2 = Vector.init(2, &dims2);
    
    try std.testing.expect(@abs(vec1.cosineSimilarity(&vec2)) < 0.001); // Should be ~0 (orthogonal)
    try std.testing.expect(@abs(vec1.magnitude() - 1.0) < 0.001); // Unit vector
}

test "LogEntry creation and retrieval" {
    const node = Node.init(1, "Test");
    const log_entry = LogEntry.initNode(node);
    
    try std.testing.expect(log_entry.getEntryType() == LogEntryType.node);
    
    const retrieved_node = log_entry.asNode().?;
    try std.testing.expect(retrieved_node.id == 1);
    try std.testing.expectEqualStrings("Test", retrieved_node.getLabelAsString());
} 