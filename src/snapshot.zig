const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");

/// Iceberg-style snapshot manager for Memora
/// Creates immutable snapshots with metadata and data files
pub const SnapshotManager = struct {
    allocator: std.mem.Allocator,
    base_path: []const u8,
    current_snapshot_id: u64,
    config: SnapshotConfig,

    pub fn init(allocator: std.mem.Allocator, base_path: []const u8, snapshot_config: ?SnapshotConfig) !SnapshotManager {
        // Use provided config or defaults
        const config_to_use = snapshot_config orelse SnapshotConfig{
            .auto_interval = 50, // Enable auto-snapshots by default every 50 log entries
            .max_metadata_size_mb = 10,
            .compression_enable = false,
            .cleanup_keep_count = 10,
            .cleanup_auto_enable = true,
            .binary_format_enable = true,
            .concurrent_writes = false,
            .verify_checksums = true,
        };

        // Create base directory structure
        try std.fs.cwd().makePath(base_path);
        
        const metadata_path = try std.fs.path.join(allocator, &[_][]const u8{ base_path, "metadata" });
        defer allocator.free(metadata_path);
        try std.fs.cwd().makePath(metadata_path);
        
        const vectors_path = try std.fs.path.join(allocator, &[_][]const u8{ base_path, "vectors" });
        defer allocator.free(vectors_path);
        try std.fs.cwd().makePath(vectors_path);
        
        const nodes_path = try std.fs.path.join(allocator, &[_][]const u8{ base_path, "nodes" });
        defer allocator.free(nodes_path);
        try std.fs.cwd().makePath(nodes_path);
        
        const edges_path = try std.fs.path.join(allocator, &[_][]const u8{ base_path, "edges" });
        defer allocator.free(edges_path);
        try std.fs.cwd().makePath(edges_path);

        const memory_contents_path = try std.fs.path.join(allocator, &[_][]const u8{ base_path, "memory_contents" });
        defer allocator.free(memory_contents_path);
        try std.fs.cwd().makePath(memory_contents_path);

        // Find the latest snapshot ID
        const latest_id = try findLatestSnapshotId(allocator, base_path);

        return SnapshotManager{
            .allocator = allocator,
            .base_path = try allocator.dupe(u8, base_path),
            .current_snapshot_id = latest_id,
            .config = config_to_use,
        };
    }

    pub fn deinit(self: *SnapshotManager) void {
        self.allocator.free(self.base_path);
    }

    /// Create a new snapshot from current data
    pub fn createSnapshot(
        self: *SnapshotManager,
        vectors: []const types.Vector,
        nodes: []const types.Node,
        edges: []const types.Edge,
        memory_contents: []const types.MemoryContent,
    ) !SnapshotInfo {
        self.current_snapshot_id += 1;
        const snapshot_id = self.current_snapshot_id;

        var info = SnapshotInfo{
            .snapshot_id = snapshot_id,
            .timestamp = try self.allocator.dupe(u8, getCurrentTimestamp()),
            .vector_files = std.ArrayList([]const u8).init(self.allocator),
            .node_files = std.ArrayList([]const u8).init(self.allocator),
            .edge_files = std.ArrayList([]const u8).init(self.allocator),
            .memory_content_files = std.ArrayList([]const u8).init(self.allocator),
            .counts = .{
                .vectors = @intCast(vectors.len),
                .nodes = @intCast(nodes.len),
                .edges = @intCast(edges.len),
                .memory_contents = @intCast(memory_contents.len),
            },
        };

        // Write vector files
        if (vectors.len > 0) {
            const vector_filename = try std.fmt.allocPrint(self.allocator, "vec-{:06}.blob", .{snapshot_id});
            defer self.allocator.free(vector_filename);
            
            const vector_path = try std.fs.path.join(self.allocator, &[_][]const u8{ "vectors", vector_filename });
            defer self.allocator.free(vector_path);
            try info.vector_files.append(try self.allocator.dupe(u8, vector_path));
            
            try self.writeVectorFile(vector_path, vectors);
        }

        // Write node files
        if (nodes.len > 0) {
            const node_filename = try std.fmt.allocPrint(self.allocator, "node-{:06}.json", .{snapshot_id});
            defer self.allocator.free(node_filename);
            
            const node_path = try std.fs.path.join(self.allocator, &[_][]const u8{ "nodes", node_filename });
            defer self.allocator.free(node_path);
            try info.node_files.append(try self.allocator.dupe(u8, node_path));
            
            try self.writeNodeFile(node_path, nodes);
        }

        // Write edge files
        if (edges.len > 0) {
            const edge_filename = try std.fmt.allocPrint(self.allocator, "edge-{:06}.json", .{snapshot_id});
            defer self.allocator.free(edge_filename);
            
            const edge_path = try std.fs.path.join(self.allocator, &[_][]const u8{ "edges", edge_filename });
            defer self.allocator.free(edge_path);
            try info.edge_files.append(try self.allocator.dupe(u8, edge_path));
            
            try self.writeEdgeFile(edge_path, edges);
        }

        // Write memory content files
        if (memory_contents.len > 0) {
            const memory_filename = try std.fmt.allocPrint(self.allocator, "memory-{:06}.json", .{snapshot_id});
            defer self.allocator.free(memory_filename);
            
            const memory_path = try std.fs.path.join(self.allocator, &[_][]const u8{ "memory_contents", memory_filename });
            defer self.allocator.free(memory_path);
            try info.memory_content_files.append(try self.allocator.dupe(u8, memory_path));
            
            try self.writeMemoryContentFile(memory_path, memory_contents);
        }

        // Write snapshot metadata
        try self.writeSnapshotMetadata(&info);

        return info;
    }

    /// Load the latest snapshot
    pub fn loadLatestSnapshot(self: *SnapshotManager) !?SnapshotInfo {
        if (self.current_snapshot_id == 0) return null;
        return self.loadSnapshot(self.current_snapshot_id);
    }

    /// Load a specific snapshot by ID
    pub fn loadSnapshot(self: *SnapshotManager, snapshot_id: u64) !?SnapshotInfo {
        const metadata_filename = try std.fmt.allocPrint(self.allocator, "snapshot-{:06}.json", .{snapshot_id});
        defer self.allocator.free(metadata_filename);
        
        const metadata_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.base_path, "metadata", metadata_filename });
        defer self.allocator.free(metadata_path);

        const file = std.fs.cwd().openFile(metadata_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close();

        const max_size_bytes = self.config.max_metadata_size_mb * 1024 * 1024;
        const content = try file.readToEndAlloc(self.allocator, max_size_bytes);
        defer self.allocator.free(content);

        return try self.parseSnapshotMetadata(content);
    }

    /// List all available snapshots
    pub fn listSnapshots(self: *SnapshotManager) !std.ArrayList(u64) {
        var snapshots = std.ArrayList(u64).init(self.allocator);
        
        const metadata_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.base_path, "metadata" });
        defer self.allocator.free(metadata_path);

        var dir = std.fs.cwd().openDir(metadata_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return snapshots,
            else => return err,
        };
        defer dir.close();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
                // Parse snapshot ID from filename: snapshot-000001.json
                if (std.mem.startsWith(u8, entry.name, "snapshot-")) {
                    const id_part = entry.name[9..15]; // Extract the 6-digit ID
                    if (std.fmt.parseInt(u64, id_part, 10)) |snapshot_id| {
                        try snapshots.append(snapshot_id);
                    } else |_| {
                        // Skip invalid filenames
                    }
                }
            }
        }

        // Sort in ascending order
        std.sort.pdq(u64, snapshots.items, {}, std.sort.asc(u64));
        return snapshots;
    }

    /// Load vectors from snapshot
    pub fn loadVectors(self: *SnapshotManager, snapshot_info: *const SnapshotInfo) !std.ArrayList(types.Vector) {
        var vectors = std.ArrayList(types.Vector).init(self.allocator);
        
        for (snapshot_info.vector_files.items) |vector_file| {
            const file_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.base_path, vector_file });
            defer self.allocator.free(file_path);
            
            const file_vectors = try self.readVectorFile(file_path);
            defer file_vectors.deinit();
            
            try vectors.appendSlice(file_vectors.items);
        }
        
        return vectors;
    }

    /// Load nodes from snapshot
    pub fn loadNodes(self: *SnapshotManager, snapshot_info: *const SnapshotInfo) !std.ArrayList(types.Node) {
        var nodes = std.ArrayList(types.Node).init(self.allocator);
        
        for (snapshot_info.node_files.items) |node_file| {
            const file_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.base_path, node_file });
            defer self.allocator.free(file_path);
            
            const file_nodes = try self.readNodeFile(file_path);
            defer file_nodes.deinit();
            
            try nodes.appendSlice(file_nodes.items);
        }
        
        return nodes;
    }

    /// Load edges from snapshot
    pub fn loadEdges(self: *SnapshotManager, snapshot_info: *const SnapshotInfo) !std.ArrayList(types.Edge) {
        var edges = std.ArrayList(types.Edge).init(self.allocator);
        
        for (snapshot_info.edge_files.items) |edge_file| {
            const file_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.base_path, edge_file });
            defer self.allocator.free(file_path);
            
            const file_edges = try self.readEdgeFile(file_path);
            defer file_edges.deinit();
            
            try edges.appendSlice(file_edges.items);
        }
        
        return edges;
    }

    /// Load memory contents from snapshot
    pub fn loadMemoryContents(self: *SnapshotManager, snapshot_info: *const SnapshotInfo) !std.ArrayList(types.MemoryContent) {
        var memory_contents = std.ArrayList(types.MemoryContent).init(self.allocator);
        
        for (snapshot_info.memory_content_files.items) |memory_file| {
            const file_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.base_path, memory_file });
            defer self.allocator.free(file_path);
            
            const file_memory_contents = try self.readMemoryContentFile(file_path);
            defer file_memory_contents.deinit(); // Only free the array list, not the content strings
            
            try memory_contents.appendSlice(file_memory_contents.items);
        }
        
        return memory_contents;
    }

    /// Delete old snapshots, keeping only the latest N
    pub fn cleanup(self: *SnapshotManager, keep_count: u32) !u32 {
        const snapshots = try self.listSnapshots();
        defer snapshots.deinit();

        if (snapshots.items.len <= keep_count) return 0;

        const delete_count = snapshots.items.len - keep_count;
        var deleted: u32 = 0;

        for (snapshots.items[0..delete_count]) |snapshot_id| {
            if (try self.deleteSnapshot(snapshot_id)) {
                deleted += 1;
            }
        }

        return deleted;
    }

    // Private methods

    fn writeVectorFile(self: *SnapshotManager, relative_path: []const u8, vectors: []const types.Vector) !void {
        const file_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.base_path, relative_path });
        defer self.allocator.free(file_path);

        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();

        // Write raw binary data: each vector is 8 bytes (id) + 128*4 bytes (dims) = 520 bytes
        for (vectors) |vector| {
            const vector_bytes = std.mem.asBytes(&vector);
            _ = try file.writeAll(vector_bytes);
        }
    }

    fn writeNodeFile(self: *SnapshotManager, relative_path: []const u8, nodes: []const types.Node) !void {
        const file_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.base_path, relative_path });
        defer self.allocator.free(file_path);

        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();

        // Write as JSON array
        try file.writeAll("[\n");
        for (nodes, 0..) |node, i| {
            if (i > 0) try file.writeAll(",\n");
            
            const json_line = try std.fmt.allocPrint(self.allocator, "  {{\"id\": {}, \"label\": \"{s}\"}}", .{ node.id, node.getLabelAsString() });
            defer self.allocator.free(json_line);
            
            try file.writeAll(json_line);
        }
        try file.writeAll("\n]\n");
    }

    fn writeEdgeFile(self: *SnapshotManager, relative_path: []const u8, edges: []const types.Edge) !void {
        const file_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.base_path, relative_path });
        defer self.allocator.free(file_path);

        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();

        // Write as JSON array
        try file.writeAll("[\n");
        for (edges, 0..) |edge, i| {
            if (i > 0) try file.writeAll(",\n");
            
            const json_line = try std.fmt.allocPrint(self.allocator, "  {{\"from\": {}, \"to\": {}, \"kind\": {}}}", .{ edge.from, edge.to, edge.kind });
            defer self.allocator.free(json_line);
            
            try file.writeAll(json_line);
        }
        try file.writeAll("\n]\n");
    }

    fn writeMemoryContentFile(self: *SnapshotManager, relative_path: []const u8, memory_contents: []const types.MemoryContent) !void {
        const file_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.base_path, relative_path });
        defer self.allocator.free(file_path);

        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();

        // Write as JSON array
        try file.writeAll("[\n");
        for (memory_contents, 0..) |memory_content, i| {
            if (i > 0) try file.writeAll(",\n");
            
            // Escape quotes in content for JSON
            var escaped_content = std.ArrayList(u8).init(self.allocator);
            defer escaped_content.deinit();
            
            for (memory_content.content) |char| {
                if (char == '"') {
                    try escaped_content.appendSlice("\\\"");
                } else if (char == '\\') {
                    try escaped_content.appendSlice("\\\\");
                } else if (char == '\n') {
                    try escaped_content.appendSlice("\\n");
                } else if (char == '\r') {
                    try escaped_content.appendSlice("\\r");
                } else if (char == '\t') {
                    try escaped_content.appendSlice("\\t");
                } else {
                    try escaped_content.append(char);
                }
            }
            
            const json_line = try std.fmt.allocPrint(self.allocator, "  {{\"memory_id\": {}, \"content\": \"{s}\"}}", .{ memory_content.memory_id, escaped_content.items });
            defer self.allocator.free(json_line);
            
            try file.writeAll(json_line);
        }
        try file.writeAll("\n]\n");
    }

    fn writeSnapshotMetadata(self: *SnapshotManager, info: *const SnapshotInfo) !void {
        const metadata_filename = try std.fmt.allocPrint(self.allocator, "snapshot-{:06}.json", .{info.snapshot_id});
        defer self.allocator.free(metadata_filename);
        
        const metadata_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.base_path, "metadata", metadata_filename });
        defer self.allocator.free(metadata_path);

        const file = try std.fs.cwd().createFile(metadata_path, .{});
        defer file.close();

        // Write JSON metadata
        try file.writeAll("{\n");
        
        const snapshot_id_str = try std.fmt.allocPrint(self.allocator, "  \"snapshot_id\": {},\n", .{info.snapshot_id});
        defer self.allocator.free(snapshot_id_str);
        try file.writeAll(snapshot_id_str);
        
        const timestamp_str = try std.fmt.allocPrint(self.allocator, "  \"timestamp\": \"{s}\",\n", .{info.timestamp});
        defer self.allocator.free(timestamp_str);
        try file.writeAll(timestamp_str);
        
        // Vector files
        try file.writeAll("  \"vector_files\": [");
        for (info.vector_files.items, 0..) |vector_file, i| {
            if (i > 0) try file.writeAll(", ");
            const vector_file_str = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{vector_file});
            defer self.allocator.free(vector_file_str);
            try file.writeAll(vector_file_str);
        }
        try file.writeAll("],\n");
        
        // Node files
        try file.writeAll("  \"node_files\": [");
        for (info.node_files.items, 0..) |node_file, i| {
            if (i > 0) try file.writeAll(", ");
            const node_file_str = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{node_file});
            defer self.allocator.free(node_file_str);
            try file.writeAll(node_file_str);
        }
        try file.writeAll("],\n");
        
        // Edge files
        try file.writeAll("  \"edge_files\": [");
        for (info.edge_files.items, 0..) |edge_file, i| {
            if (i > 0) try file.writeAll(", ");
            const edge_file_str = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{edge_file});
            defer self.allocator.free(edge_file_str);
            try file.writeAll(edge_file_str);
        }
        try file.writeAll("],\n");
        
        // Memory content files
        try file.writeAll("  \"memory_content_files\": [");
        for (info.memory_content_files.items, 0..) |memory_file, i| {
            if (i > 0) try file.writeAll(", ");
            const memory_file_str = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{memory_file});
            defer self.allocator.free(memory_file_str);
            try file.writeAll(memory_file_str);
        }
        try file.writeAll("],\n");
        
        // Counts
        const counts_json = try std.fmt.allocPrint(self.allocator, "  \"counts\": {{\"vectors\": {}, \"nodes\": {}, \"edges\": {}, \"memory_contents\": {}}}\n", .{ info.counts.vectors, info.counts.nodes, info.counts.edges, info.counts.memory_contents });
        defer self.allocator.free(counts_json);
        try file.writeAll(counts_json);
        
        try file.writeAll("}\n");
    }

    fn readVectorFile(self: *SnapshotManager, file_path: []const u8) !std.ArrayList(types.Vector) {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        const vector_size = @sizeOf(types.Vector);
        const vector_count = file_size / vector_size;

        var vectors = std.ArrayList(types.Vector).init(self.allocator);
        try vectors.ensureTotalCapacity(vector_count);

        var i: usize = 0;
        while (i < vector_count) : (i += 1) {
            var vector_bytes: [@sizeOf(types.Vector)]u8 = undefined;
            const bytes_read = try file.readAll(&vector_bytes);
            if (bytes_read != vector_size) break;
            
            const vector = std.mem.bytesToValue(types.Vector, &vector_bytes);
            try vectors.append(vector);
        }

        return vectors;
    }

    fn readNodeFile(self: *SnapshotManager, file_path: []const u8) !std.ArrayList(types.Node) {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        return try self.parseNodesJson(content);
    }

    fn readEdgeFile(self: *SnapshotManager, file_path: []const u8) !std.ArrayList(types.Edge) {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        var edges = std.ArrayList(types.Edge).init(self.allocator);

        // Parse JSON array - basic parsing since we control the format
        var start: usize = 0;
        while (std.mem.indexOf(u8, content[start..], "{\"from\":")) |pos| {
            const json_start = start + pos;
            if (std.mem.indexOf(u8, content[json_start..], "}")) |end_pos| {
                const json_end = json_start + end_pos + 1;
                const json_str = content[json_start..json_end];
                
                const edge = try self.parseEdgeJson(json_str);
                try edges.append(edge);
                start = json_end;
            } else break;
        }

        return edges;
    }

    fn readMemoryContentFile(self: *SnapshotManager, file_path: []const u8) !std.ArrayList(types.MemoryContent) {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        var memory_contents = std.ArrayList(types.MemoryContent).init(self.allocator);

        // Parse JSON array - basic parsing since we control the format
        var start: usize = 0;
        while (std.mem.indexOf(u8, content[start..], "{\"memory_id\":")) |pos| {
            const json_start = start + pos;
            if (std.mem.indexOf(u8, content[json_start..], "}")) |end_pos| {
                const json_end = json_start + end_pos + 1;
                const json_str = content[json_start..json_end];
                
                const memory_content = try self.parseMemoryContentJson(json_str);
                try memory_contents.append(memory_content);
                start = json_end;
            } else break;
        }

        return memory_contents;
    }

    fn parseSnapshotMetadata(self: *SnapshotManager, json_content: []const u8) !SnapshotInfo {
        // Simple JSON parsing for snapshot metadata
        // In a real implementation, you'd use a proper JSON parser
        var info = SnapshotInfo{
            .snapshot_id = 0,
            .timestamp = try self.allocator.dupe(u8, getCurrentTimestamp()), // Default timestamp
            .vector_files = std.ArrayList([]const u8).init(self.allocator),
            .node_files = std.ArrayList([]const u8).init(self.allocator),
            .edge_files = std.ArrayList([]const u8).init(self.allocator),
            .memory_content_files = std.ArrayList([]const u8).init(self.allocator),
            .counts = .{ .vectors = 0, .nodes = 0, .edges = 0, .memory_contents = 0 },
        };

        // This is a simplified parser - in production, use std.json
        var lines = std.mem.splitSequence(u8, json_content, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n,");
            if (std.mem.indexOf(u8, trimmed, "\"snapshot_id\":")) |_| {
                // Extract snapshot_id
                if (std.mem.indexOf(u8, trimmed, ":")) |colon_idx| {
                    const value_part = std.mem.trim(u8, trimmed[colon_idx + 1 ..], " ,");
                    info.snapshot_id = std.fmt.parseInt(u64, value_part, 10) catch 0;
                }
            } else if (std.mem.indexOf(u8, trimmed, "\"timestamp\":")) |_| {
                // Extract timestamp
                if (std.mem.indexOf(u8, trimmed, ":")) |colon_idx| {
                    const after_colon = trimmed[colon_idx + 1 ..];
                    if (std.mem.indexOf(u8, after_colon, "\"")) |quote1| {
                        const timestamp_content = after_colon[quote1 + 1 ..];
                        if (std.mem.indexOf(u8, timestamp_content, "\"")) |quote2| {
                            const timestamp_str = timestamp_content[0..quote2];
                            // Free the default timestamp and set the parsed one
                            self.allocator.free(info.timestamp);
                            info.timestamp = try self.allocator.dupe(u8, timestamp_str);
                        }
                    }
                }
            } else if (std.mem.indexOf(u8, trimmed, "\"vector_files\":")) |_| {
                // Parse vector_files array
                try self.parseFileArray(trimmed, &info.vector_files);
            } else if (std.mem.indexOf(u8, trimmed, "\"node_files\":")) |_| {
                // Parse node_files array  
                try self.parseFileArray(trimmed, &info.node_files);
            } else if (std.mem.indexOf(u8, trimmed, "\"edge_files\":")) |_| {
                // Parse edge_files array
                try self.parseFileArray(trimmed, &info.edge_files);
            } else if (std.mem.indexOf(u8, trimmed, "\"memory_content_files\":")) |_| {
                // Parse memory_content_files array
                try self.parseFileArray(trimmed, &info.memory_content_files);
            }
        }

        return info;
    }

    fn parseFileArray(self: *SnapshotManager, line: []const u8, file_list: *std.ArrayList([]const u8)) !void {
        // Parse JSON array like: "vector_files": ["vectors/vec-000001.blob", "vectors/vec-000002.blob"]
        if (std.mem.indexOf(u8, line, "[")) |start_bracket| {
            if (std.mem.indexOf(u8, line[start_bracket..], "]")) |end_bracket_offset| {
                const end_bracket = start_bracket + end_bracket_offset;
                const array_content = line[start_bracket + 1..end_bracket];
                
                // Split by commas and extract quoted strings
                var parts = std.mem.splitScalar(u8, array_content, ',');
                while (parts.next()) |part| {
                    const trimmed_part = std.mem.trim(u8, part, " \t");
                    if (std.mem.indexOf(u8, trimmed_part, "\"")) |quote1| {
                        const after_quote1 = trimmed_part[quote1 + 1..];
                        if (std.mem.indexOf(u8, after_quote1, "\"")) |quote2| {
                            const file_path = after_quote1[0..quote2];
                            if (file_path.len > 0) {
                                try file_list.append(try self.allocator.dupe(u8, file_path));
                            }
                        }
                    }
                }
            }
        }
    }

    fn parseNodesJson(self: *SnapshotManager, json_content: []const u8) !std.ArrayList(types.Node) {
        var nodes = std.ArrayList(types.Node).init(self.allocator);
        
        // Simple JSON parsing - extract id and label pairs
        var lines = std.mem.splitSequence(u8, json_content, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n,");
            if (std.mem.indexOf(u8, trimmed, "\"id\":") != null and std.mem.indexOf(u8, trimmed, "\"label\":") != null) {
                // Parse a node line: {"id": 1, "label": "Test"}
                var id: u64 = 0;
                var label: [32]u8 = [_]u8{0} ** 32;
                
                // Extract ID
                if (std.mem.indexOf(u8, trimmed, "\"id\":")) |id_start| {
                    const after_id = trimmed[id_start + 5 ..];
                    if (std.mem.indexOf(u8, after_id, ",")) |comma_idx| {
                        const id_str = std.mem.trim(u8, after_id[0..comma_idx], " ");
                        id = std.fmt.parseInt(u64, id_str, 10) catch 0;
                    }
                }
                
                // Extract label
                if (std.mem.indexOf(u8, trimmed, "\"label\":")) |label_start| {
                    const after_label = trimmed[label_start + 8 ..];
                    if (std.mem.indexOf(u8, after_label, "\"")) |quote1| {
                        const label_content = after_label[quote1 + 1 ..];
                        if (std.mem.indexOf(u8, label_content, "\"")) |quote2| {
                            const label_str = label_content[0..quote2];
                            const copy_len = @min(label_str.len, 31);
                            @memcpy(label[0..copy_len], label_str[0..copy_len]);
                        }
                    }
                }
                
                try nodes.append(types.Node{ .id = id, .label = label });
            }
        }
        
        return nodes;
    }

    fn parseEdgeJson(self: *SnapshotManager, json_str: []const u8) !types.Edge {
        // Parse JSON string to Edge
        _ = self; // Mark unused
        var edge = types.Edge{ .from = 0, .to = 0, .kind = 0 };
        var parts = std.mem.splitScalar(u8, json_str, ',');
                while (parts.next()) |part| {
                    const trimmed_part = std.mem.trim(u8, part, " {}");
                    if (std.mem.indexOf(u8, trimmed_part, "\"from\":")) |_| {
                        if (std.mem.indexOf(u8, trimmed_part, ":")) |colon_idx| {
                            const value_str = std.mem.trim(u8, trimmed_part[colon_idx + 1 ..], " ");
                    edge.from = std.fmt.parseInt(u64, value_str, 10) catch 0;
                        }
                    } else if (std.mem.indexOf(u8, trimmed_part, "\"to\":")) |_| {
                        if (std.mem.indexOf(u8, trimmed_part, ":")) |colon_idx| {
                            const value_str = std.mem.trim(u8, trimmed_part[colon_idx + 1 ..], " ");
                    edge.to = std.fmt.parseInt(u64, value_str, 10) catch 0;
                        }
                    } else if (std.mem.indexOf(u8, trimmed_part, "\"kind\":")) |_| {
                        if (std.mem.indexOf(u8, trimmed_part, ":")) |colon_idx| {
                            const value_str = std.mem.trim(u8, trimmed_part[colon_idx + 1 ..], " ");
                    edge.kind = std.fmt.parseInt(u8, value_str, 10) catch 0;
                        }
                    }
                }
        return edge;
    }

    fn parseMemoryContentJson(self: *SnapshotManager, json_str: []const u8) !types.MemoryContent {
        // Parse JSON string to MemoryContent
        var memory_id: u64 = 0;
        var content_str: []const u8 = "";
        
        // Find memory_id
        if (std.mem.indexOf(u8, json_str, "\"memory_id\":")) |id_start| {
            const id_colon = id_start + 12; // skip "memory_id":
            if (std.mem.indexOf(u8, json_str[id_colon..], ",")) |comma_pos| {
                const id_str = std.mem.trim(u8, json_str[id_colon..id_colon + comma_pos], " ");
                memory_id = std.fmt.parseInt(u64, id_str, 10) catch 0;
            }
        }
        
        // Find content
        if (std.mem.indexOf(u8, json_str, "\"content\":")) |content_start| {
            const content_colon = content_start + 10; // skip "content":
            if (std.mem.indexOf(u8, json_str[content_colon..], "\"")) |quote_start| {
                const content_begin = content_colon + quote_start + 1;
                if (std.mem.lastIndexOf(u8, json_str[content_begin..], "\"")) |quote_end| {
                    content_str = json_str[content_begin..content_begin + quote_end];
                    
                    // Unescape JSON strings
                    var unescaped_content = std.ArrayList(u8).init(self.allocator);
                    defer unescaped_content.deinit();
                    
                    var i: usize = 0;
                    while (i < content_str.len) {
                        if (content_str[i] == '\\' and i + 1 < content_str.len) {
                            switch (content_str[i + 1]) {
                                '"' => try unescaped_content.append('"'),
                                '\\' => try unescaped_content.append('\\'),
                                'n' => try unescaped_content.append('\n'),
                                'r' => try unescaped_content.append('\r'),
                                't' => try unescaped_content.append('\t'),
                                else => {
                                    try unescaped_content.append(content_str[i]);
                                    try unescaped_content.append(content_str[i + 1]);
                                },
                            }
                            i += 2;
                        } else {
                            try unescaped_content.append(content_str[i]);
                            i += 1;
            }
        }
        
                    const final_content = try self.allocator.dupe(u8, unescaped_content.items);
                    return types.MemoryContent{ .memory_id = memory_id, .content = final_content };
                }
            }
        }
        
        return types.MemoryContent{ .memory_id = memory_id, .content = try self.allocator.dupe(u8, "") };
    }

    fn deleteSnapshot(self: *SnapshotManager, snapshot_id: u64) !bool {
        const snapshot_info = (try self.loadSnapshot(snapshot_id)) orelse return false;
        defer snapshot_info.deinit();

        // Delete all data files
        for (snapshot_info.vector_files.items) |vector_file| {
            const file_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.base_path, vector_file });
            defer self.allocator.free(file_path);
            std.fs.cwd().deleteFile(file_path) catch {};
        }

        for (snapshot_info.node_files.items) |node_file| {
            const file_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.base_path, node_file });
            defer self.allocator.free(file_path);
            std.fs.cwd().deleteFile(file_path) catch {};
        }

        for (snapshot_info.edge_files.items) |edge_file| {
            const file_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.base_path, edge_file });
            defer self.allocator.free(file_path);
            std.fs.cwd().deleteFile(file_path) catch {};
        }

        // Delete metadata file
        const metadata_filename = try std.fmt.allocPrint(self.allocator, "snapshot-{:06}.json", .{snapshot_id});
        defer self.allocator.free(metadata_filename);
        
        const metadata_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.base_path, "metadata", metadata_filename });
        defer self.allocator.free(metadata_path);
        
        std.fs.cwd().deleteFile(metadata_path) catch {};

        return true;
    }
};

pub const SnapshotInfo = struct {
    snapshot_id: u64,
    timestamp: []const u8,
    vector_files: std.ArrayList([]const u8),
    node_files: std.ArrayList([]const u8),
    edge_files: std.ArrayList([]const u8),
    memory_content_files: std.ArrayList([]const u8),
    counts: struct {
        vectors: u64,
        nodes: u64,
        edges: u64,
        memory_contents: u64,
    },

    pub fn deinit(self: *const SnapshotInfo) void {
        for (self.vector_files.items) |file| {
            self.vector_files.allocator.free(file);
        }
        self.vector_files.deinit();
        
        for (self.node_files.items) |file| {
            self.node_files.allocator.free(file);
        }
        self.node_files.deinit();
        
        for (self.edge_files.items) |file| {
            self.edge_files.allocator.free(file);
        }
        self.edge_files.deinit();
        
        for (self.memory_content_files.items) |file| {
            self.memory_content_files.allocator.free(file);
        }
        self.memory_content_files.deinit();
        
        self.vector_files.allocator.free(self.timestamp);
    }
};

fn findLatestSnapshotId(allocator: std.mem.Allocator, base_path: []const u8) !u64 {
    const metadata_path = try std.fs.path.join(allocator, &[_][]const u8{ base_path, "metadata" });
    defer allocator.free(metadata_path);

    var dir = std.fs.cwd().openDir(metadata_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close();

    var max_id: u64 = 0;
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind == .file and std.mem.startsWith(u8, entry.name, "snapshot-") and std.mem.endsWith(u8, entry.name, ".json")) {
            const id_part = entry.name[9..15]; // Extract the 6-digit ID
            if (std.fmt.parseInt(u64, id_part, 10)) |snapshot_id| {
                max_id = @max(max_id, snapshot_id);
            } else |_| {
                // Skip invalid filenames
            }
        }
    }

    return max_id;
}

fn getCurrentTimestamp() []const u8 {
    // For simplicity, return a fixed timestamp format
    // In production, use proper ISO 8601 formatting
    return "2025-01-13T00:00:00Z";
}

test "SnapshotManager creation and cleanup" {
    const allocator = std.testing.allocator;
    const base_path = "test_snapshots";
    
    // Clean up any existing test data
    std.fs.cwd().deleteTree(base_path) catch {};
    
    var manager = try SnapshotManager.init(allocator, base_path, null);
    defer manager.deinit();
    defer std.fs.cwd().deleteTree(base_path) catch {};

    // Test empty snapshot list
    const empty_snapshots = try manager.listSnapshots();
    defer empty_snapshots.deinit();
    try std.testing.expect(empty_snapshots.items.len == 0);
}

test "SnapshotManager create and load snapshot" {
    const allocator = std.testing.allocator;
    const base_path = "test_snapshots_2";
    
    // Clean up any existing test data
    std.fs.cwd().deleteTree(base_path) catch {};
    
    var manager = try SnapshotManager.init(allocator, base_path, null);
    defer manager.deinit();
    defer std.fs.cwd().deleteTree(base_path) catch {};

    // Create test data
    const test_nodes = [_]types.Node{
        types.Node.init(1, "TestNode1"),
        types.Node.init(2, "TestNode2"),
    };
    
    const test_edges = [_]types.Edge{
        types.Edge.init(1, 2, types.EdgeKind.owns),
    };
    
    const dims = [_]f32{ 1.0, 0.0, 0.0 } ++ [_]f32{0.0} ** 125;
    const test_vectors = [_]types.Vector{
        types.Vector.init(1, &dims),
    };

    // Create snapshot
    const snapshot_info = try manager.createSnapshot(&test_vectors, &test_nodes, &test_edges, &[_]types.MemoryContent{});
    defer snapshot_info.deinit();

    try std.testing.expect(snapshot_info.snapshot_id == 1);
    try std.testing.expect(snapshot_info.counts.nodes == 2);
    try std.testing.expect(snapshot_info.counts.edges == 1);
    try std.testing.expect(snapshot_info.counts.vectors == 1);

    // Load snapshot back
    const loaded_info = (try manager.loadSnapshot(1)).?;
    defer loaded_info.deinit();
    
    try std.testing.expect(loaded_info.snapshot_id == 1);
}

/// Snapshot configuration helper
pub const SnapshotConfig = struct {
    auto_interval: u32,
    max_metadata_size_mb: u32,
    compression_enable: bool,
    cleanup_keep_count: u32,
    cleanup_auto_enable: bool,
    binary_format_enable: bool,
    concurrent_writes: bool,
    verify_checksums: bool,
    
    pub fn fromConfig(global_cfg: config.Config) SnapshotConfig {
        return SnapshotConfig{
            .auto_interval = global_cfg.snapshot_auto_interval,
            .max_metadata_size_mb = global_cfg.snapshot_max_metadata_size_mb,
            .compression_enable = global_cfg.snapshot_compression_enable,
            .cleanup_keep_count = global_cfg.snapshot_cleanup_keep_count,
            .cleanup_auto_enable = global_cfg.snapshot_cleanup_auto_enable,
            .binary_format_enable = global_cfg.snapshot_binary_format_enable,
            .concurrent_writes = global_cfg.snapshot_concurrent_writes,
            .verify_checksums = global_cfg.snapshot_verify_checksums,
        };
    }
};

test "SnapshotConfig from global config" {
    const global_config = config.Config{
        .snapshot_auto_interval = 250,
        .snapshot_max_metadata_size_mb = 20,
        .snapshot_compression_enable = true,
        .snapshot_cleanup_keep_count = 5,
        .snapshot_cleanup_auto_enable = false,
        .snapshot_binary_format_enable = false,
        .snapshot_concurrent_writes = true,
        .snapshot_verify_checksums = false,
    };
    
    const snapshot_cfg = SnapshotConfig.fromConfig(global_config);
    try std.testing.expect(snapshot_cfg.auto_interval == 250);
    try std.testing.expect(snapshot_cfg.max_metadata_size_mb == 20);
    try std.testing.expect(snapshot_cfg.compression_enable == true);
    try std.testing.expect(snapshot_cfg.cleanup_keep_count == 5);
    try std.testing.expect(snapshot_cfg.cleanup_auto_enable == false);
    try std.testing.expect(snapshot_cfg.binary_format_enable == false);
    try std.testing.expect(snapshot_cfg.concurrent_writes == true);
    try std.testing.expect(snapshot_cfg.verify_checksums == false);
}

test "SnapshotManager with custom configuration" {
    const allocator = std.testing.allocator;
    const base_path = "test_snapshot_config";
    
    // Clean up any existing test data
    std.fs.cwd().deleteTree(base_path) catch {};
    defer std.fs.cwd().deleteTree(base_path) catch {};
    
    // Create custom snapshot config
    const snapshot_config = SnapshotConfig{
        .auto_interval = 100,
        .max_metadata_size_mb = 5,
        .compression_enable = false,
        .cleanup_keep_count = 3,
        .cleanup_auto_enable = true,
        .binary_format_enable = true,
        .concurrent_writes = false,
        .verify_checksums = true,
    };
    
    var manager = try SnapshotManager.init(allocator, base_path, snapshot_config);
    defer manager.deinit();
    
    // Verify configuration was applied
    try std.testing.expect(manager.config.auto_interval == 100);
    try std.testing.expect(manager.config.max_metadata_size_mb == 5);
    try std.testing.expect(manager.config.cleanup_keep_count == 3);
    try std.testing.expect(manager.config.cleanup_auto_enable == true);
    try std.testing.expect(manager.config.binary_format_enable == true);
    try std.testing.expect(manager.config.verify_checksums == true);
}

test "SnapshotManager with default configuration" {
    const allocator = std.testing.allocator;
    const base_path = "test_snapshot_default";
    
    // Clean up any existing test data
    std.fs.cwd().deleteTree(base_path) catch {};
    defer std.fs.cwd().deleteTree(base_path) catch {};
    
    var manager = try SnapshotManager.init(allocator, base_path, null);
    defer manager.deinit();
    
    // Verify default configuration
    try std.testing.expect(manager.config.auto_interval == 50);
    try std.testing.expect(manager.config.max_metadata_size_mb == 10);
    try std.testing.expect(manager.config.compression_enable == false);
    try std.testing.expect(manager.config.cleanup_keep_count == 10);
    try std.testing.expect(manager.config.cleanup_auto_enable == true);
    try std.testing.expect(manager.config.binary_format_enable == true);
    try std.testing.expect(manager.config.concurrent_writes == false);
    try std.testing.expect(manager.config.verify_checksums == true);
}

test "SnapshotManager configuration integration test" {
    const allocator = std.testing.allocator;
    const base_path = "test_snapshot_integration";
    
    // Clean up any existing test data
    std.fs.cwd().deleteTree(base_path) catch {};
    defer std.fs.cwd().deleteTree(base_path) catch {};
    
    // Create a comprehensive global config
    const global_config = config.Config{
        .snapshot_auto_interval = 150,
        .snapshot_max_metadata_size_mb = 15,
        .snapshot_compression_enable = false,
        .snapshot_cleanup_keep_count = 7,
        .snapshot_cleanup_auto_enable = true,
        .snapshot_binary_format_enable = true,
        .snapshot_concurrent_writes = false,
        .snapshot_verify_checksums = true,
    };
    
    // Test SnapshotConfig.fromConfig
    const snapshot_cfg = SnapshotConfig.fromConfig(global_config);
    try std.testing.expect(snapshot_cfg.auto_interval == 150);
    try std.testing.expect(snapshot_cfg.max_metadata_size_mb == 15);
    try std.testing.expect(snapshot_cfg.cleanup_keep_count == 7);
    
    // Test SnapshotManager with the config
    var manager = try SnapshotManager.init(allocator, base_path, snapshot_cfg);
    defer manager.deinit();
    
    // Verify integration works end-to-end
    try std.testing.expect(manager.config.auto_interval == 150);
    try std.testing.expect(manager.config.max_metadata_size_mb == 15);
    try std.testing.expect(manager.config.cleanup_keep_count == 7);
    
    // Test that configuration affects actual operations
    const test_nodes = [_]types.Node{
        types.Node.init(1, "TestNode1"),
        types.Node.init(2, "TestNode2"),
    };
    
    // Create snapshot with correct parameter order: vectors, nodes, edges
    const snapshot_info = try manager.createSnapshot(&[_]types.Vector{}, &test_nodes, &[_]types.Edge{}, &[_]types.MemoryContent{});
    defer snapshot_info.deinit();
    
    // Verify snapshot was created successfully
    try std.testing.expect(snapshot_info.snapshot_id > 0);
    try std.testing.expect(snapshot_info.counts.nodes == 2);
    try std.testing.expect(snapshot_info.counts.vectors == 0);
    try std.testing.expect(snapshot_info.counts.edges == 0);
    
    std.debug.print("✓ Snapshot configuration integration test passed\n", .{});
} 