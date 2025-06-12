const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");
const compression = @import("compression.zig");

/// Memory-Mapped Persistent Index System
/// Provides instant startup and crash-safe index persistence
/// Following TigerBeetle-style programming: deterministic, comprehensive, zero dependencies

/// Persistent index configuration helper
pub const PersistentIndexConfig = struct {
    enable: bool,
    sync_interval: u32,
    auto_rebuild: bool,
    memory_alignment: u32,
    checksum_validation: bool,
    auto_cleanup: bool,
    max_file_size_mb: u32,
    compression_enable: bool,
    sync_on_shutdown: bool,
    
    pub fn fromConfig(global_config: config.Config) PersistentIndexConfig {
        return PersistentIndexConfig{
            .enable = global_config.persistent_index_enable,
            .sync_interval = global_config.persistent_index_sync_interval,
            .auto_rebuild = global_config.persistent_index_auto_rebuild,
            .memory_alignment = global_config.persistent_index_memory_alignment,
            .checksum_validation = global_config.persistent_index_checksum_validation,
            .auto_cleanup = global_config.persistent_index_auto_cleanup,
            .max_file_size_mb = global_config.persistent_index_max_file_size_mb,
            .compression_enable = global_config.persistent_index_compression_enable,
            .sync_on_shutdown = global_config.persistent_index_sync_on_shutdown,
        };
    }
};

/// File header for persistent index files
pub const IndexFileHeader = struct {
    magic: u32 = 0x49444558, // "IDEX" in little-endian
    version: u16 = 1,
    index_type: IndexType,
    checksum: u32, // CRC32 of entire file contents after header
    created_timestamp: u64,
    item_count: u64,
    data_offset: u64, // Offset to start of data section
    // NEW: Compression support
    compression_method: compression.CompressionMethod = .none,
    compressed_size: u64 = 0, // Size of compressed data (0 if uncompressed)
    original_size: u64 = 0, // Original uncompressed size
    padding: [16]u8 = [_]u8{0} ** 16, // Adjusted padding for alignment
    
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
    mapping: []u8, // Simplified - let Zig handle alignment
    size: usize,
    path: []const u8,
    allocator: std.mem.Allocator,
    alignment: u32,
    
    pub fn init(allocator: std.mem.Allocator, path: []const u8, size: usize, alignment: u32) !MappedFile {
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
            .alignment = alignment,
        };
    }
    
    pub fn initReadOnly(allocator: std.mem.Allocator, path: []const u8, alignment: u32) !MappedFile {
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
            .alignment = alignment,
        };
    }
    
    pub fn deinit(self: *MappedFile) void {
        std.posix.munmap(@alignCast(self.mapping));
        self.file.close();
        self.allocator.free(self.path);
    }
    
    pub fn sync(self: *MappedFile) !void {
        try std.posix.msync(@alignCast(self.mapping), std.posix.MSF.SYNC);
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
        var data_start = header.data_offset;
        
        if (data_start >= self.size) return error.InvalidDataOffset;
        
        // Ensure data start is properly aligned for type T
        const alignment = @alignOf(T);
        const misalignment = data_start % alignment;
        if (misalignment != 0) {
            data_start += alignment - misalignment;
        }
        
        if (data_start >= self.size) return error.InvalidDataOffset;
        
        const remaining_bytes = self.size - data_start;
        const item_count = remaining_bytes / @sizeOf(T);
        
        if (item_count == 0) {
            return &[_]T{}; // Return empty slice instead of attempting pointer cast
        }
        
        const data_ptr = self.mapping.ptr + data_start;
        const aligned_ptr = @as([*]const T, @ptrCast(@alignCast(data_ptr)));
        return aligned_ptr[0..item_count];
    }
    
    pub fn getDataSliceMutable(self: *MappedFile, comptime T: type) ![]T {
        const header = try self.getHeader();
        var data_start = header.data_offset;
        
        if (data_start >= self.size) return error.InvalidDataOffset;
        
        // Ensure data start is properly aligned for type T
        const alignment = @alignOf(T);
        const misalignment = data_start % alignment;
        if (misalignment != 0) {
            data_start += alignment - misalignment;
        }
        
        if (data_start >= self.size) return error.InvalidDataOffset;
        
        const remaining_bytes = self.size - data_start;
        const item_count = remaining_bytes / @sizeOf(T);
        
        if (item_count == 0) {
            return &[_]T{}; // Return empty slice instead of attempting pointer cast
        }
        
        const data_ptr = self.mapping.ptr + data_start;
        const aligned_ptr = @as([*]T, @ptrCast(@alignCast(data_ptr)));
        return aligned_ptr[0..item_count];
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
        // Clean up existing mapped file if it exists
        if (self.mapped_file) |*existing_file| {
            existing_file.deinit();
            self.mapped_file = null;
        }
        
        const header_size = @sizeOf(IndexFileHeader);
        // Ensure data offset is aligned for Node structure
        const node_alignment = @alignOf(types.Node);
        const aligned_data_offset = std.mem.alignForward(usize, header_size, node_alignment);
        const data_size = nodes.len * @sizeOf(types.Node);
        const total_size = @max(aligned_data_offset + data_size, header_size + 1); // Ensure minimum size
        
        // Create memory-mapped file
        var mapped_file = try MappedFile.init(self.allocator, self.path, total_size, 16384);
        
        // Initialize header
        const header = try mapped_file.getHeaderMutable();
        header.* = IndexFileHeader{
            .index_type = .graph_nodes,
            .checksum = 0, // Will be calculated later
            .created_timestamp = @intCast(std.time.timestamp()),
            .item_count = nodes.len,
            .data_offset = aligned_data_offset,
        };
        
        // Copy node data only if we have nodes
        if (nodes.len > 0) {
            const data_slice = try mapped_file.getDataSliceMutable(types.Node);
            @memcpy(data_slice[0..nodes.len], nodes);
        }
        
        // Calculate and set checksum (for data after header)
        const data_section = mapped_file.mapping[aligned_data_offset..];
        header.checksum = calculateChecksum(data_section);
        
        // Sync to disk
        try mapped_file.sync();
        
        self.mapped_file = mapped_file;
    }
    
    pub fn load(self: *PersistentNodeIndex) ![]const types.Node {
        if (self.mapped_file == null) {
            self.mapped_file = MappedFile.initReadOnly(self.allocator, self.path, 16384) catch |err| switch (err) {
                error.FileNotFound => return &[_]types.Node{}, // No index exists yet
                else => return err,
            };
        }
        
        const file = &self.mapped_file.?;
        const header = file.getHeader() catch |err| {
            // Clean up on header read error
            file.deinit();
            self.mapped_file = null;
            return err;
        };
        
        // Validate header
        if (header.magic != 0x49444558) {
            file.deinit();
            self.mapped_file = null;
            return error.InvalidMagic;
        }
        if (header.index_type != .graph_nodes) {
            file.deinit();
            self.mapped_file = null;
            return error.WrongIndexType;
        }
        
        // Validate checksum
        const data_section = file.mapping[header.data_offset..];
        const expected_checksum = calculateChecksum(data_section);
        if (header.checksum != expected_checksum) {
            file.deinit();
            self.mapped_file = null;
            return error.ChecksumMismatch;
        }
        
        return file.getDataSlice(types.Node) catch |err| {
            // Clean up on data slice error
            file.deinit();
            self.mapped_file = null;
            return err;
        };
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
        // Clean up existing mapped file if it exists
        if (self.mapped_file) |*existing_file| {
            existing_file.deinit();
            self.mapped_file = null;
        }
        
        const header_size = @sizeOf(IndexFileHeader);
        // Ensure data offset is aligned for Edge structure
        const edge_alignment = @alignOf(types.Edge);
        const aligned_data_offset = std.mem.alignForward(usize, header_size, edge_alignment);
        const data_size = edges.len * @sizeOf(types.Edge);
        const total_size = @max(aligned_data_offset + data_size, header_size + 1); // Ensure minimum size
        
        var mapped_file = try MappedFile.init(self.allocator, self.path, total_size, 16384);
        
        const header = try mapped_file.getHeaderMutable();
        header.* = IndexFileHeader{
            .index_type = .graph_edges,
            .checksum = 0,
            .created_timestamp = @intCast(std.time.timestamp()),
            .item_count = edges.len,
            .data_offset = aligned_data_offset,
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
        
        const data_section = mapped_file.mapping[aligned_data_offset..];
        header.checksum = calculateChecksum(data_section);
        try mapped_file.sync();
        
        self.mapped_file = mapped_file;
    }
    
    pub fn load(self: *PersistentEdgeIndex) ![]const types.Edge {
        if (self.mapped_file == null) {
            self.mapped_file = MappedFile.initReadOnly(self.allocator, self.path, 16384) catch |err| switch (err) {
                error.FileNotFound => return &[_]types.Edge{},
                else => return err,
            };
        }
        
        const file = &self.mapped_file.?;
        const header = file.getHeader() catch |err| {
            // Clean up on header read error
            file.deinit();
            self.mapped_file = null;
            return err;
        };
        
        if (header.magic != 0x49444558) {
            file.deinit();
            self.mapped_file = null;
            return error.InvalidMagic;
        }
        if (header.index_type != .graph_edges) {
            file.deinit();
            self.mapped_file = null;
            return error.WrongIndexType;
        }
        
        const data_section = file.mapping[header.data_offset..];
        const expected_checksum = calculateChecksum(data_section);
        if (header.checksum != expected_checksum) {
            file.deinit();
            self.mapped_file = null;
            return error.ChecksumMismatch;
        }
        
        return file.getDataSlice(types.Edge) catch |err| {
            // Clean up on data slice error
            file.deinit();
            self.mapped_file = null;
            return err;
        };
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

/// Persistent Vector Index - stores vectors in binary format with compression
pub const PersistentVectorIndex = struct {
    mapped_file: ?MappedFile,
    allocator: std.mem.Allocator,
    path: []const u8,
    compression_engine: ?*compression.CompressionEngine,
    
    pub fn init(allocator: std.mem.Allocator, index_dir: []const u8) !PersistentVectorIndex {
        const path = try std.fs.path.join(allocator, &[_][]const u8{ index_dir, "vectors.idx" });
        
        return PersistentVectorIndex{
            .mapped_file = null,
            .allocator = allocator,
            .path = path,
            .compression_engine = null,
        };
    }
    
    /// Initialize with compression engine
    pub fn initWithCompression(allocator: std.mem.Allocator, index_dir: []const u8, compression_engine: *compression.CompressionEngine) !PersistentVectorIndex {
        var index = try init(allocator, index_dir);
        index.compression_engine = compression_engine;
        return index;
    }
    
    pub fn deinit(self: *PersistentVectorIndex) void {
        if (self.mapped_file) |*file| {
            file.deinit();
        }
        self.allocator.free(self.path);
    }
    
    pub fn create(self: *PersistentVectorIndex, vectors: []const types.Vector) !void {
        // Clean up existing mapped file if it exists
        if (self.mapped_file) |*existing_file| {
            existing_file.deinit();
            self.mapped_file = null;
        }
        
        const header_size = @sizeOf(IndexFileHeader);
        // Ensure data offset is aligned for Vector structure
        const vector_alignment = @alignOf(types.Vector);
        const aligned_data_offset = std.mem.alignForward(usize, header_size, vector_alignment);
        var data_size = vectors.len * @sizeOf(types.Vector);
        var compressed_data: ?compression.CompressedVectorData = null;
        var use_compression = false;
        
        // Try compression if engine is available and enabled
        if (self.compression_engine) |engine| {
            // Only compress if we have a reasonable amount of data
            if (vectors.len >= 100) {
                compressed_data = engine.compressVectors(vectors) catch null;
                if (compressed_data) |comp_data| {
                    // Use compression if it saves at least 20% space
                    if (comp_data.compression_ratio >= 1.2) {
                        data_size = comp_data.compressed_data.len;
                        use_compression = true;
                    }
                }
            }
        }
        
        const total_size = @max(aligned_data_offset + data_size, header_size + 1); // Ensure minimum size
        var mapped_file = try MappedFile.init(self.allocator, self.path, total_size, 16384);
        
        const header = try mapped_file.getHeaderMutable();
        header.* = IndexFileHeader{
            .index_type = .vector_data,
            .checksum = 0,
            .created_timestamp = @intCast(std.time.timestamp()),
            .item_count = vectors.len,
            .data_offset = aligned_data_offset,
            .compression_method = if (use_compression) .vector_quantized else .none,
            .compressed_size = if (use_compression) data_size else 0,
            .original_size = vectors.len * @sizeOf(types.Vector),
        };
        
        if (use_compression and compressed_data != null) {
            // Write compressed data
            const comp_data = compressed_data.?;
            @memcpy(mapped_file.mapping[aligned_data_offset..aligned_data_offset + data_size], comp_data.compressed_data);
            
            // Calculate checksum of compressed data
            const data_section = mapped_file.mapping[aligned_data_offset..aligned_data_offset + data_size];
            header.checksum = calculateChecksum(data_section);
            
            // Clean up compressed data
            var mut_comp_data = comp_data;
            mut_comp_data.deinit(self.allocator);
        } else {
            // Write uncompressed data (sorted by ID for binary search)
            if (vectors.len > 0) {
                const data_slice = try mapped_file.getDataSliceMutable(types.Vector);
                @memcpy(data_slice[0..vectors.len], vectors);
                
                // Sort vectors by ID for binary search
                std.sort.pdq(types.Vector, data_slice[0..vectors.len], {}, struct {
                    fn lessThan(_: void, a: types.Vector, b: types.Vector) bool {
                        return a.id < b.id;
                    }
                }.lessThan);
                
                // Calculate checksum of uncompressed data
                const data_section = mapped_file.mapping[aligned_data_offset..];
                header.checksum = calculateChecksum(data_section);
            }
        }
        
        try mapped_file.sync();
        self.mapped_file = mapped_file;
    }
    
    pub fn load(self: *PersistentVectorIndex) ![]const types.Vector {
        if (self.mapped_file == null) {
            self.mapped_file = MappedFile.initReadOnly(self.allocator, self.path, 16384) catch |err| switch (err) {
                error.FileNotFound => return &[_]types.Vector{},
                else => return err,
            };
        }
        
        const file = &self.mapped_file.?;
        const header = try file.getHeader();
        
        if (header.magic != 0x49444558) return error.InvalidMagic;
        if (header.index_type != .vector_data) return error.WrongIndexType;
        
        // Handle compressed data
        if (header.compression_method != .none) {
            if (self.compression_engine == null) {
                return error.CompressionEngineRequired;
            }
            
            const compressed_data_slice = file.mapping[header.data_offset..header.data_offset + header.compressed_size];
            const expected_checksum = calculateChecksum(compressed_data_slice);
            if (header.checksum != expected_checksum) return error.ChecksumMismatch;
            
            const compressed_data = compression.CompressedVectorData{
                .compressed_data = @constCast(compressed_data_slice),
                .original_count = @intCast(header.item_count),
                .compression_method = header.compression_method,
                .compression_ratio = @as(f32, @floatFromInt(header.original_size)) / @as(f32, @floatFromInt(header.compressed_size)),
            };
            
            // Decompress and return vectors
            var decompressed_vectors = try self.compression_engine.?.decompressVectors(&compressed_data);
            defer decompressed_vectors.deinit();
            
            // Store decompressed vectors in a persistent way
            // Note: This is a simplified approach - in production you might want to cache this
            const persistent_vectors = try self.allocator.alloc(types.Vector, decompressed_vectors.items.len);
            @memcpy(persistent_vectors, decompressed_vectors.items);
            
            return persistent_vectors;
        } else {
            // Handle uncompressed data
            const data_section = file.mapping[header.data_offset..];
            const expected_checksum = calculateChecksum(data_section);
            if (header.checksum != expected_checksum) return error.ChecksumMismatch;
            
            return try file.getDataSlice(types.Vector);
        }
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
    config: PersistentIndexConfig,
    node_index: PersistentNodeIndex,
    edge_index: PersistentEdgeIndex,
    vector_index: PersistentVectorIndex,
    
    pub fn init(allocator: std.mem.Allocator, data_path: []const u8, persistent_config: ?PersistentIndexConfig) !PersistentIndexManager {
        const cfg = persistent_config orelse PersistentIndexConfig.fromConfig(config.Config{});
        
        const index_dir = try std.fs.path.join(allocator, &[_][]const u8{ data_path, "indexes" });
        
        // Ensure index directory exists only if persistent indexes are enabled
        if (cfg.enable) {
            std.fs.cwd().makeDir(index_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
        
        return PersistentIndexManager{
            .allocator = allocator,
            .index_dir = index_dir,
            .config = cfg,
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
        
        // Check if persistent indexes are enabled
        if (!self.config.enable) {
            return; // Skip saving if disabled
        }
        
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
        // Check if persistent indexes are enabled
        if (!self.config.enable) {
            return .{
                .nodes = &[_]types.Node{},
                .edges = &[_]types.Edge{},
                .vectors = &[_]types.Vector{},
            };
        }
        
        // Load all indexes, handling partial failures gracefully
        var nodes: []const types.Node = &[_]types.Node{};
        var edges: []const types.Edge = &[_]types.Edge{};
        var vectors: []const types.Vector = &[_]types.Vector{};
        
        // Load nodes
        nodes = self.node_index.load() catch |err| {
            // If node loading fails, return error immediately
            return err;
        };
        errdefer {
            // Clean up nodes if later operations fail
            if (self.node_index.mapped_file) |*file| {
                file.deinit();
                self.node_index.mapped_file = null;
            }
        }
        
        // Load edges
        edges = self.edge_index.load() catch |err| {
            // Clean up nodes before returning error
            if (self.node_index.mapped_file) |*file| {
                file.deinit();
                self.node_index.mapped_file = null;
            }
            return err;
        };
        errdefer {
            // Clean up edges if later operations fail
            if (self.edge_index.mapped_file) |*file| {
                file.deinit();
                self.edge_index.mapped_file = null;
            }
        }
        
        // Load vectors
        vectors = self.vector_index.load() catch |err| {
            // Clean up nodes and edges before returning error
            if (self.node_index.mapped_file) |*file| {
                file.deinit();
                self.node_index.mapped_file = null;
            }
            if (self.edge_index.mapped_file) |*file| {
                file.deinit();
                self.edge_index.mapped_file = null;
            }
            return err;
        };
        
        return .{
            .nodes = nodes,
            .edges = edges,
            .vectors = vectors,
        };
    }
    
    /// Check if persistent indexes exist
    pub fn indexesExist(self: *const PersistentIndexManager) bool {
        if (!self.config.enable) {
            return false; // If disabled, always return false
        }
        
        return self.node_index.exists() and 
               self.edge_index.exists() and 
               self.vector_index.exists();
    }
    
    /// Check if persistent indexes are enabled in configuration
    pub fn isEnabled(self: *const PersistentIndexManager) bool {
        return self.config.enable;
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

test "PersistentIndexConfig from global config" {
    const global_config = config.Config{
        .persistent_index_enable = false,
        .persistent_index_sync_interval = 250,
        .persistent_index_auto_rebuild = false,
        .persistent_index_memory_alignment = 32768,
        .persistent_index_checksum_validation = false,
        .persistent_index_auto_cleanup = true,
        .persistent_index_max_file_size_mb = 2048,
        .persistent_index_compression_enable = true,
        .persistent_index_sync_on_shutdown = false,
    };
    
    const persistent_config = PersistentIndexConfig.fromConfig(global_config);
    
    try std.testing.expect(persistent_config.enable == false);
    try std.testing.expect(persistent_config.sync_interval == 250);
    try std.testing.expect(persistent_config.auto_rebuild == false);
    try std.testing.expect(persistent_config.memory_alignment == 32768);
    try std.testing.expect(persistent_config.checksum_validation == false);
    try std.testing.expect(persistent_config.auto_cleanup == true);
    try std.testing.expect(persistent_config.max_file_size_mb == 2048);
    try std.testing.expect(persistent_config.compression_enable == true);
    try std.testing.expect(persistent_config.sync_on_shutdown == false);
}

test "PersistentIndexManager with custom configuration" {
    const allocator = std.testing.allocator;
    
    // Clean up any existing test data
    std.fs.cwd().deleteTree("test_persistent_config") catch {};
    defer std.fs.cwd().deleteTree("test_persistent_config") catch {};
    
    // Create the parent directory
    try std.fs.cwd().makeDir("test_persistent_config");
    
    const persistent_config = PersistentIndexConfig{
        .enable = true,
        .sync_interval = 50,
        .auto_rebuild = true,
        .memory_alignment = 65536,
        .checksum_validation = true,
        .auto_cleanup = false,
        .max_file_size_mb = 512,
        .compression_enable = false,
        .sync_on_shutdown = true,
    };
    
    var manager = try PersistentIndexManager.init(allocator, "test_persistent_config", persistent_config);
    defer manager.deinit();
    
    // Verify configuration is applied
    try std.testing.expect(manager.config.enable == true);
    try std.testing.expect(manager.config.sync_interval == 50);
    try std.testing.expect(manager.config.auto_rebuild == true);
    try std.testing.expect(manager.config.memory_alignment == 65536);
    try std.testing.expect(manager.config.checksum_validation == true);
    try std.testing.expect(manager.config.auto_cleanup == false);
    try std.testing.expect(manager.config.max_file_size_mb == 512);
    try std.testing.expect(manager.config.compression_enable == false);
    try std.testing.expect(manager.config.sync_on_shutdown == true);
    
    // Test that methods respect configuration
    try std.testing.expect(manager.isEnabled() == true);
    try std.testing.expect(manager.indexesExist() == false); // No indexes created yet
}

test "PersistentIndexManager with disabled configuration" {
    const allocator = std.testing.allocator;
    
    const persistent_config = PersistentIndexConfig{
        .enable = false,
        .sync_interval = 100,
        .auto_rebuild = true,
        .memory_alignment = 16384,
        .checksum_validation = true,
        .auto_cleanup = true,
        .max_file_size_mb = 1024,
        .compression_enable = false,
        .sync_on_shutdown = true,
    };
    
    var manager = try PersistentIndexManager.init(allocator, "test_disabled_persistent", persistent_config);
    defer manager.deinit();
    
    // Verify disabled state
    try std.testing.expect(manager.isEnabled() == false);
    try std.testing.expect(manager.indexesExist() == false);
    
    // Test that save/load operations are no-ops when disabled
    const nodes = [_]types.Node{types.Node.init(1, "TestNode")};
    const edges = [_]types.Edge{types.Edge.init(1, 2, types.EdgeKind.owns)};
    const dims = [_]f32{1.0} ++ [_]f32{0.0} ** 127;
    const vectors = [_]types.Vector{types.Vector.init(1, &dims)};
    
    // Save should succeed but do nothing
    try manager.saveIndexes(&nodes, &edges, &vectors);
    
    // Load should return empty data
    const loaded_data = try manager.loadIndexes();
    try std.testing.expect(loaded_data.nodes.len == 0);
    try std.testing.expect(loaded_data.edges.len == 0);
    try std.testing.expect(loaded_data.vectors.len == 0);
}

test "PersistentIndexManager with default configuration" {
    const allocator = std.testing.allocator;
    
    // Clean up any existing test data
    std.fs.cwd().deleteTree("test_default_persistent") catch {};
    defer std.fs.cwd().deleteTree("test_default_persistent") catch {};
    
    // Create the parent directory
    try std.fs.cwd().makeDir("test_default_persistent");
    
    var manager = try PersistentIndexManager.init(allocator, "test_default_persistent", null);
    defer manager.deinit();
    
    // Verify default values are applied
    try std.testing.expect(manager.config.enable == true);
    try std.testing.expect(manager.config.sync_interval == 100);
    try std.testing.expect(manager.config.auto_rebuild == true);
    try std.testing.expect(manager.config.memory_alignment == 16384);
    try std.testing.expect(manager.config.checksum_validation == true);
    try std.testing.expect(manager.config.auto_cleanup == true);
    try std.testing.expect(manager.config.max_file_size_mb == 1024);
    try std.testing.expect(manager.config.compression_enable == true);
    try std.testing.expect(manager.config.sync_on_shutdown == true);
    
    try std.testing.expect(manager.isEnabled() == true);
}

test "Persistent index configuration integration with global config" {
    const allocator = std.testing.allocator;
    
    // Create a comprehensive global config
    const global_config = config.Config{
        .persistent_index_enable = true,
        .persistent_index_sync_interval = 75,
        .persistent_index_auto_rebuild = false,
        .persistent_index_memory_alignment = 8192,
        .persistent_index_checksum_validation = false,
        .persistent_index_auto_cleanup = false,
        .persistent_index_max_file_size_mb = 256,
        .persistent_index_compression_enable = true,
        .persistent_index_sync_on_shutdown = false,
    };
    
    // Test PersistentIndexConfig.fromConfig
    const persistent_cfg = PersistentIndexConfig.fromConfig(global_config);
    try std.testing.expect(persistent_cfg.enable == true);
    try std.testing.expect(persistent_cfg.sync_interval == 75);
    try std.testing.expect(persistent_cfg.auto_rebuild == false);
    try std.testing.expect(persistent_cfg.memory_alignment == 8192);
    try std.testing.expect(persistent_cfg.checksum_validation == false);
    try std.testing.expect(persistent_cfg.auto_cleanup == false);
    try std.testing.expect(persistent_cfg.max_file_size_mb == 256);
    try std.testing.expect(persistent_cfg.compression_enable == true);
    try std.testing.expect(persistent_cfg.sync_on_shutdown == false);
    
    // Clean up any existing test data
    std.fs.cwd().deleteTree("test_integration_persistent") catch {};
    defer std.fs.cwd().deleteTree("test_integration_persistent") catch {};
    
    // Create the parent directory
    try std.fs.cwd().makeDir("test_integration_persistent");
    
    // Test PersistentIndexManager with the config
    var manager = try PersistentIndexManager.init(allocator, "test_integration_persistent", persistent_cfg);
    defer manager.deinit();
    
    // Verify integration works end-to-end
    try std.testing.expect(manager.config.enable == true);
    try std.testing.expect(manager.config.sync_interval == 75);
    try std.testing.expect(manager.config.memory_alignment == 8192);
    try std.testing.expect(manager.isEnabled() == true);
} 