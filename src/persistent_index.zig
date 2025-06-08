const std = @import("std");
const types = @import("types.zig");

/// Memory-Mapped Persistent Index System
/// Provides instant startup and crash-safe index persistence
/// Following TigerBeetle-style programming: deterministic, comprehensive, zero dependencies

/// Header for all persistent index files
pub const IndexFileHeader = struct {
    magic: u32 = 0x49444558, // "IDEX" in little-endian
    version: u16 = 1,
    index_type: IndexType,
    checksum: u32, // CRC32 of entire file contents after header
    created_timestamp: u64,
    item_count: u64,
    data_offset: u64, // Offset to start of data section
    padding: [24]u8 = [_]u8{0} ** 24, // Adjusted padding for alignment
    
    pub const IndexType = enum(u8) {
        graph_nodes = 1,
        graph_edges = 2,  
        vector_data = 3,
        adjacency_lists = 4,
    };
    
    // Note: struct size may vary due to alignment, so we'll calculate it dynamically
};

/// Memory-mapped file wrapper for safe access
pub const MappedFile = struct {
    file: std.fs.File,
    mapping: []align(16384) u8, // Use correct alignment for munmap
    size: usize,
    path: []const u8,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, path: []const u8, size: usize) !MappedFile {
        const file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = false });
        
        // Ensure file is correct size
        try file.seekTo(size - 1);
        _ = try file.write(&[_]u8{0});
        try file.seekTo(0);
        
        const mapping = try std.posix.mmap(
            null,
            size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            file.handle,
            0
        );
        
        const path_copy = try allocator.dupe(u8, path);
        
        return MappedFile{
            .file = file,
            .mapping = mapping,
            .size = size,
            .path = path_copy,
            .allocator = allocator,
        };
    }
    
    pub fn initReadOnly(allocator: std.mem.Allocator, path: []const u8) !MappedFile {
        const file = try std.fs.cwd().openFile(path, .{});
        const file_size = try file.getEndPos();
        
        const mapping = try std.posix.mmap(
            null,
            file_size,
            std.posix.PROT.READ,
            .{ .TYPE = .SHARED },
            file.handle,
            0
        );
        
        const path_copy = try allocator.dupe(u8, path);
        
        return MappedFile{
            .file = file,
            .mapping = mapping,
            .size = file_size,
            .path = path_copy,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *MappedFile) void {
        std.posix.munmap(self.mapping);
        self.file.close();
        self.allocator.free(self.path);
    }
    
    pub fn sync(self: *MappedFile) !void {
        try std.posix.msync(self.mapping, std.posix.MSF.SYNC);
    }
    
    pub fn getHeader(self: *const MappedFile) !*const IndexFileHeader {
        if (self.size < @sizeOf(IndexFileHeader)) return error.FileTooSmall;
        return @ptrCast(@alignCast(self.mapping.ptr));
    }
    
    pub fn getHeaderMutable(self: *MappedFile) !*IndexFileHeader {
        if (self.size < @sizeOf(IndexFileHeader)) return error.FileTooSmall;
        return @ptrCast(@alignCast(self.mapping.ptr));
    }
    
    pub fn getDataSlice(self: *const MappedFile, comptime T: type) ![]const T {
        const header = try self.getHeader();
        const data_start = header.data_offset;
        
        if (data_start >= self.size) return error.InvalidDataOffset;
        
        const remaining_bytes = self.size - data_start;
        const item_count = remaining_bytes / @sizeOf(T);
        
        const data_ptr = self.mapping.ptr + data_start;
        return @as([*]const T, @ptrCast(@alignCast(data_ptr)))[0..item_count];
    }
    
    pub fn getDataSliceMutable(self: *MappedFile, comptime T: type) ![]T {
        const header = try self.getHeader();
        const data_start = header.data_offset;
        
        if (data_start >= self.size) return error.InvalidDataOffset;
        
        const remaining_bytes = self.size - data_start;
        const item_count = remaining_bytes / @sizeOf(T);
        
        const data_ptr = self.mapping.ptr + data_start;
        return @as([*]T, @ptrCast(@alignCast(data_ptr)))[0..item_count];
    }
};

/// Persistent Node Index - stores all nodes in a memory-mapped file
pub const PersistentNodeIndex = struct {
    mapped_file: ?MappedFile,
    allocator: std.mem.Allocator,
    path: []const u8,
    
    pub fn init(allocator: std.mem.Allocator, index_dir: []const u8) !PersistentNodeIndex {
        const path = try std.fs.path.join(allocator, &[_][]const u8{ index_dir, "nodes.idx" });
        
        return PersistentNodeIndex{
            .mapped_file = null,
            .allocator = allocator,
            .path = path,
        };
    }
    
    pub fn deinit(self: *PersistentNodeIndex) void {
        if (self.mapped_file) |*file| {
            file.deinit();
        }
        self.allocator.free(self.path);
    }
    
    pub fn create(self: *PersistentNodeIndex, nodes: []const types.Node) !void {
        const header_size = @sizeOf(IndexFileHeader);
        const data_size = nodes.len * @sizeOf(types.Node);
        const total_size = @max(header_size + data_size, header_size + 1); // Ensure minimum size
        
        // Create memory-mapped file
        var mapped_file = try MappedFile.init(self.allocator, self.path, total_size);
        
        // Initialize header
        const header = try mapped_file.getHeaderMutable();
        header.* = IndexFileHeader{
            .index_type = .graph_nodes,
            .checksum = 0, // Will be calculated later
            .created_timestamp = @intCast(std.time.timestamp()),
            .item_count = nodes.len,
            .data_offset = header_size,
        };
        
        // Copy node data only if we have nodes
        if (nodes.len > 0) {
            const data_slice = try mapped_file.getDataSliceMutable(types.Node);
            @memcpy(data_slice[0..nodes.len], nodes);
        }
        
        // Calculate and set checksum (for data after header)
        const data_section = mapped_file.mapping[@sizeOf(IndexFileHeader)..];
        header.checksum = calculateChecksum(data_section);
        
        // Sync to disk
        try mapped_file.sync();
        
        self.mapped_file = mapped_file;
    }
    
    pub fn load(self: *PersistentNodeIndex) ![]const types.Node {
        if (self.mapped_file == null) {
            self.mapped_file = MappedFile.initReadOnly(self.allocator, self.path) catch |err| switch (err) {
                error.FileNotFound => return &[_]types.Node{}, // No index exists yet
                else => return err,
            };
        }
        
        const file = &self.mapped_file.?;
        const header = try file.getHeader();
        
        // Validate header
        if (header.magic != 0x49444558) return error.InvalidMagic;
        if (header.index_type != .graph_nodes) return error.WrongIndexType;
        
        // Validate checksum
        const data_section = file.mapping[@sizeOf(IndexFileHeader)..];
        const expected_checksum = calculateChecksum(data_section);
        if (header.checksum != expected_checksum) return error.ChecksumMismatch;
        
        return try file.getDataSlice(types.Node);
    }
    
    pub fn exists(self: *const PersistentNodeIndex) bool {
        std.fs.cwd().access(self.path, .{}) catch return false;
        return true;
    }
};

/// Persistent Edge Index - stores edges with efficient lookups
pub const PersistentEdgeIndex = struct {
    mapped_file: ?MappedFile,
    allocator: std.mem.Allocator,
    path: []const u8,
    
    pub fn init(allocator: std.mem.Allocator, index_dir: []const u8) !PersistentEdgeIndex {
        const path = try std.fs.path.join(allocator, &[_][]const u8{ index_dir, "edges.idx" });
        
        return PersistentEdgeIndex{
            .mapped_file = null,
            .allocator = allocator,
            .path = path,
        };
    }
    
    pub fn deinit(self: *PersistentEdgeIndex) void {
        if (self.mapped_file) |*file| {
            file.deinit();
        }
        self.allocator.free(self.path);
    }
    
    pub fn create(self: *PersistentEdgeIndex, edges: []const types.Edge) !void {
        const header_size = @sizeOf(IndexFileHeader);
        const data_size = edges.len * @sizeOf(types.Edge);
        const total_size = @max(header_size + data_size, header_size + 1); // Ensure minimum size
        
        var mapped_file = try MappedFile.init(self.allocator, self.path, total_size);
        
        const header = try mapped_file.getHeaderMutable();
        header.* = IndexFileHeader{
            .index_type = .graph_edges,
            .checksum = 0,
            .created_timestamp = @intCast(std.time.timestamp()),
            .item_count = edges.len,
            .data_offset = header_size,
        };
        
        // Copy and sort edges for efficient access only if we have edges
        if (edges.len > 0) {
            const data_slice = try mapped_file.getDataSliceMutable(types.Edge);
            @memcpy(data_slice[0..edges.len], edges);
            
            // Sort edges by (from, to) for binary search
            std.sort.pdq(types.Edge, data_slice[0..edges.len], {}, struct {
                fn lessThan(_: void, a: types.Edge, b: types.Edge) bool {
                    if (a.from != b.from) return a.from < b.from;
                    return a.to < b.to;
                }
            }.lessThan);
        }
        
        const data_section = mapped_file.mapping[@sizeOf(IndexFileHeader)..];
        header.checksum = calculateChecksum(data_section);
        try mapped_file.sync();
        
        self.mapped_file = mapped_file;
    }
    
    pub fn load(self: *PersistentEdgeIndex) ![]const types.Edge {
        if (self.mapped_file == null) {
            self.mapped_file = MappedFile.initReadOnly(self.allocator, self.path) catch |err| switch (err) {
                error.FileNotFound => return &[_]types.Edge{},
                else => return err,
            };
        }
        
        const file = &self.mapped_file.?;
        const header = try file.getHeader();
        
        if (header.magic != 0x49444558) return error.InvalidMagic;
        if (header.index_type != .graph_edges) return error.WrongIndexType;
        
        const data_section = file.mapping[@sizeOf(IndexFileHeader)..];
        const expected_checksum = calculateChecksum(data_section);
        if (header.checksum != expected_checksum) return error.ChecksumMismatch;
        
        return try file.getDataSlice(types.Edge);
    }
    
    pub fn exists(self: *const PersistentEdgeIndex) bool {
        std.fs.cwd().access(self.path, .{}) catch return false;
        return true;
    }
    
    /// Find edges with specific 'from' node using binary search
    pub fn findEdgesFrom(self: *PersistentEdgeIndex, from_node: u64) ![]const types.Edge {
        const all_edges = try self.load();
        
        // Find first edge with matching 'from'
        const start_idx = std.sort.lowerBound(types.Edge, all_edges, types.Edge{ .from = from_node, .to = 0, .kind = 0 }, struct {
            fn compare(key: types.Edge, edge: types.Edge) std.math.Order {
                return std.math.order(key.from, edge.from);
            }
        }.compare);
        
        if (start_idx >= all_edges.len or all_edges[start_idx].from != from_node) {
            return &[_]types.Edge{};
        }
        
        // Find last edge with matching 'from'
        const end_idx = std.sort.upperBound(types.Edge, all_edges, types.Edge{ .from = from_node, .to = std.math.maxInt(u64), .kind = 255 }, struct {
            fn compare(key: types.Edge, edge: types.Edge) std.math.Order {
                return std.math.order(key.from, edge.from);
            }
        }.compare);
        
        return all_edges[start_idx..end_idx];
    }
};

/// Persistent Vector Index - stores vectors in binary format
pub const PersistentVectorIndex = struct {
    mapped_file: ?MappedFile,
    allocator: std.mem.Allocator,
    path: []const u8,
    
    pub fn init(allocator: std.mem.Allocator, index_dir: []const u8) !PersistentVectorIndex {
        const path = try std.fs.path.join(allocator, &[_][]const u8{ index_dir, "vectors.idx" });
        
        return PersistentVectorIndex{
            .mapped_file = null,
            .allocator = allocator,
            .path = path,
        };
    }
    
    pub fn deinit(self: *PersistentVectorIndex) void {
        if (self.mapped_file) |*file| {
            file.deinit();
        }
        self.allocator.free(self.path);
    }
    
    pub fn create(self: *PersistentVectorIndex, vectors: []const types.Vector) !void {
        const header_size = @sizeOf(IndexFileHeader);
        const data_size = vectors.len * @sizeOf(types.Vector);
        const total_size = @max(header_size + data_size, header_size + 1); // Ensure minimum size
        
        var mapped_file = try MappedFile.init(self.allocator, self.path, total_size);
        
        const header = try mapped_file.getHeaderMutable();
        header.* = IndexFileHeader{
            .index_type = .vector_data,
            .checksum = 0,
            .created_timestamp = @intCast(std.time.timestamp()),
            .item_count = vectors.len,
            .data_offset = header_size,
        };
        
        // Copy and sort vectors only if we have vectors
        if (vectors.len > 0) {
            const data_slice = try mapped_file.getDataSliceMutable(types.Vector);
            @memcpy(data_slice[0..vectors.len], vectors);
            
            // Sort vectors by ID for binary search
            std.sort.pdq(types.Vector, data_slice[0..vectors.len], {}, struct {
                fn lessThan(_: void, a: types.Vector, b: types.Vector) bool {
                    return a.id < b.id;
                }
            }.lessThan);
        }
        
        const data_section = mapped_file.mapping[@sizeOf(IndexFileHeader)..];
        header.checksum = calculateChecksum(data_section);
        try mapped_file.sync();
        
        self.mapped_file = mapped_file;
    }
    
    pub fn load(self: *PersistentVectorIndex) ![]const types.Vector {
        if (self.mapped_file == null) {
            self.mapped_file = MappedFile.initReadOnly(self.allocator, self.path) catch |err| switch (err) {
                error.FileNotFound => return &[_]types.Vector{},
                else => return err,
            };
        }
        
        const file = &self.mapped_file.?;
        const header = try file.getHeader();
        
        if (header.magic != 0x49444558) return error.InvalidMagic;
        if (header.index_type != .vector_data) return error.WrongIndexType;
        
        const data_section = file.mapping[@sizeOf(IndexFileHeader)..];
        const expected_checksum = calculateChecksum(data_section);
        if (header.checksum != expected_checksum) return error.ChecksumMismatch;
        
        return try file.getDataSlice(types.Vector);
    }
    
    pub fn exists(self: *const PersistentVectorIndex) bool {
        std.fs.cwd().access(self.path, .{}) catch return false;
        return true;
    }
    
    /// Find vector by ID using binary search
    pub fn findVector(self: *PersistentVectorIndex, vector_id: u64) !?types.Vector {
        const all_vectors = try self.load();
        
        const idx = std.sort.binarySearch(types.Vector, all_vectors, types.Vector{ .id = vector_id, .dims = undefined }, struct {
            fn compare(key: types.Vector, vector: types.Vector) std.math.Order {
                return std.math.order(key.id, vector.id);
            }
        }.compare);
        
        if (idx) |found_idx| {
            return all_vectors[found_idx];
        }
        return null;
    }
};

/// Persistent Index Manager - coordinates all persistent indexes
pub const PersistentIndexManager = struct {
    allocator: std.mem.Allocator,
    index_dir: []const u8,
    node_index: PersistentNodeIndex,
    edge_index: PersistentEdgeIndex,
    vector_index: PersistentVectorIndex,
    
    pub fn init(allocator: std.mem.Allocator, data_path: []const u8) !PersistentIndexManager {
        const index_dir = try std.fs.path.join(allocator, &[_][]const u8{ data_path, "indexes" });
        
        // Ensure index directory exists
        std.fs.cwd().makeDir(index_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        
        return PersistentIndexManager{
            .allocator = allocator,
            .index_dir = index_dir,
            .node_index = try PersistentNodeIndex.init(allocator, index_dir),
            .edge_index = try PersistentEdgeIndex.init(allocator, index_dir),
            .vector_index = try PersistentVectorIndex.init(allocator, index_dir),
        };
    }
    
    pub fn deinit(self: *PersistentIndexManager) void {
        self.node_index.deinit();
        self.edge_index.deinit();
        self.vector_index.deinit();
        self.allocator.free(self.index_dir);
    }
    
    /// Save all in-memory indexes to persistent storage
    pub fn saveIndexes(self: *PersistentIndexManager, 
                      nodes: []const types.Node, 
                      edges: []const types.Edge, 
                      vectors: []const types.Vector) !void {
        
        try self.node_index.create(nodes);
        try self.edge_index.create(edges);
        try self.vector_index.create(vectors);
    }
    
    /// Load all indexes from persistent storage
    pub fn loadIndexes(self: *PersistentIndexManager) !struct {
        nodes: []const types.Node,
        edges: []const types.Edge,
        vectors: []const types.Vector,
    } {
        return .{
            .nodes = try self.node_index.load(),
            .edges = try self.edge_index.load(),
            .vectors = try self.vector_index.load(),
        };
    }
    
    /// Check if persistent indexes exist
    pub fn indexesExist(self: *const PersistentIndexManager) bool {
        return self.node_index.exists() and 
               self.edge_index.exists() and 
               self.vector_index.exists();
    }
    
    /// Get index statistics
    pub fn getStats(self: *PersistentIndexManager) !IndexStats {
        var stats = IndexStats{};
        
        if (self.node_index.exists()) {
            const nodes = try self.node_index.load();
            stats.node_count = nodes.len;
        }
        
        if (self.edge_index.exists()) {
            const edges = try self.edge_index.load();
            stats.edge_count = edges.len;
        }
        
        if (self.vector_index.exists()) {
            const vectors = try self.vector_index.load();
            stats.vector_count = vectors.len;
        }
        
        return stats;
    }
};

pub const IndexStats = struct {
    node_count: usize = 0,
    edge_count: usize = 0,
    vector_count: usize = 0,
};

/// Calculate CRC32 checksum for data integrity
fn calculateChecksum(data: []const u8) u32 {
    const Crc32 = std.hash.Crc32;
    return Crc32.hash(data);
}

/// Utility functions for efficient index operations
pub const IndexUtils = struct {
    
    /// Convert in-memory graph to arrays for persistence
    pub fn graphToArrays(graph_index: anytype, allocator: std.mem.Allocator) !struct {
        nodes: std.ArrayList(types.Node),
        edges: std.ArrayList(types.Edge),
    } {
        var nodes = std.ArrayList(types.Node).init(allocator);
        var edges = std.ArrayList(types.Edge).init(allocator);
        
        // Extract nodes
        var node_iter = graph_index.nodes.iterator();
        while (node_iter.next()) |entry| {
            try nodes.append(entry.value_ptr.*);
        }
        
        // Extract edges (avoiding duplicates)
        var edge_set = std.AutoHashMap(types.Edge, void).init(allocator);
        defer edge_set.deinit();
        
        var outgoing_iter = graph_index.outgoing_edges.iterator();
        while (outgoing_iter.next()) |entry| {
            for (entry.value_ptr.items) |edge| {
                try edge_set.put(edge, {});
            }
        }
        
        var edge_iter = edge_set.iterator();
        while (edge_iter.next()) |entry| {
            try edges.append(entry.key_ptr.*);
        }
        
        return .{ .nodes = nodes, .edges = edges };
    }
    
    /// Convert in-memory vector index to array for persistence
    pub fn vectorsToArray(vector_index: anytype, allocator: std.mem.Allocator) !std.ArrayList(types.Vector) {
        var vectors = std.ArrayList(types.Vector).init(allocator);
        
        var iter = vector_index.vectors.iterator();
        while (iter.next()) |entry| {
            try vectors.append(entry.value_ptr.*);
        }
        
        return vectors;
    }
}; 