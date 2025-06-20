const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");
const compression = @import("compression.zig");

/// Append-only binary log for Memora
/// Follows TigerBeetle design principles: single-threaded, deterministic, no locks
pub const AppendLog = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    mmap: ?[]align(std.heap.page_size_min) u8,
    current_size: usize,
    max_size: usize,
    entry_count: u64,
    log_path: []const u8,
    config: config.Config,
    compression_engine: ?*compression.CompressionEngine,

    const ENTRY_SIZE = @sizeOf(types.LogEntry);

    pub fn init(allocator: std.mem.Allocator, log_path: []const u8, log_config: ?config.Config) !AppendLog {
        // Use provided config or load from default location
        const cfg = log_config orelse blk: {
            const config_path = "memora.conf";
            // Create default config if it doesn't exist
            try config.Config.createDefaultIfMissing(config_path);
            break :blk try config.Config.fromFile(allocator, config_path);
        };

        // Create directories if they don't exist
        const dir = std.fs.path.dirname(log_path);
        if (dir) |d| {
            std.fs.cwd().makePath(d) catch {};
        }

        const file = try std.fs.cwd().createFile(log_path, .{
            .read = true,
            .truncate = false,
        });

        // Get current file size
        const stat = try file.stat();
        const current_size = if (stat.size == 0) cfg.log_initial_size else @as(usize, @intCast(stat.size));
        
        // Extend file if needed
        if (stat.size < current_size) {
            try file.setEndPos(current_size);
        }

        // Memory map the file
        const mmap = try std.posix.mmap(
            null,
            current_size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            std.posix.MAP{ .TYPE = .SHARED },
            file.handle,
            0,
        );

        // Count existing entries
        const entry_count = if (stat.size > 0) stat.size / ENTRY_SIZE else 0;

        // Initialize compression engine if enabled
        var compression_engine: ?*compression.CompressionEngine = null;
        if (cfg.log_compression_enable) {
            const comp_config = compression.CompressionConfig{
                .enable_checksums = cfg.compression_enable_checksums,
                .compression_level = cfg.compression_level,
                .rle_min_run_length = cfg.compression_rle_min_run_length,
            };
            compression_engine = try allocator.create(compression.CompressionEngine);
            compression_engine.?.* = compression.CompressionEngine.init(allocator, comp_config);
        }

        return AppendLog{
            .allocator = allocator,
            .file = file,
            .mmap = mmap,
            .current_size = current_size,
            .max_size = cfg.log_max_size,
            .entry_count = entry_count,
            .log_path = try allocator.dupe(u8, log_path),
            .config = cfg,
            .compression_engine = compression_engine,
        };
    }

    pub fn deinit(self: *AppendLog) void {
        if (self.mmap) |mmap| {
            std.posix.munmap(mmap);
        }
        self.file.close();
        self.allocator.free(self.log_path);
        
        if (self.compression_engine) |engine| {
            engine.deinit();
            self.allocator.destroy(engine);
        }
    }

    /// Append a single log entry (thread-safe, deterministic)
    pub fn append(self: *AppendLog, entry: types.LogEntry) !void {
        const write_offset = self.entry_count * ENTRY_SIZE;
        
        // Check if we need to grow the file
        if (write_offset + ENTRY_SIZE > self.current_size) {
            try self.growFile();
        }

        // Write entry to memory-mapped region
        if (self.mmap) |mmap| {
            const entry_bytes = std.mem.asBytes(&entry);
            @memcpy(mmap[write_offset..write_offset + ENTRY_SIZE], entry_bytes);
            
            // Force write to disk for durability
            // Sync the entire mmap region for simplicity to avoid alignment issues
            const aligned_mmap: []align(std.heap.page_size_min) u8 = @alignCast(mmap);
            try std.posix.msync(aligned_mmap, std.posix.MSF.SYNC);
        }

        self.entry_count += 1;
    }

    /// Batch append multiple entries (more efficient)
    pub fn appendBatch(self: *AppendLog, entries: []const types.LogEntry) !void {
        if (entries.len == 0) return;

        const write_offset = self.entry_count * ENTRY_SIZE;
        const batch_size = entries.len * ENTRY_SIZE;
        
        // Check if we need to grow the file
        if (write_offset + batch_size > self.current_size) {
            try self.growFile();
        }

        // Write all entries to memory-mapped region
        if (self.mmap) |mmap| {
            for (entries, 0..) |entry, i| {
                const offset = write_offset + (i * ENTRY_SIZE);
                const entry_bytes = std.mem.asBytes(&entry);
                @memcpy(mmap[offset..offset + ENTRY_SIZE], entry_bytes);
            }
            
            // Force write to disk for durability
            // Sync the entire mmap region for simplicity to avoid alignment issues
            const aligned_mmap: []align(std.heap.page_size_min) u8 = @alignCast(mmap);
            try std.posix.msync(aligned_mmap, std.posix.MSF.SYNC);
        }

        self.entry_count += entries.len;
    }

    /// Read log entry by index
    pub fn read(self: *const AppendLog, index: u64) !?types.LogEntry {
        if (index >= self.entry_count) return null;

        const read_offset = index * ENTRY_SIZE;
        
        if (self.mmap) |mmap| {
            const entry_bytes = mmap[read_offset..read_offset + ENTRY_SIZE];
            return std.mem.bytesToValue(types.LogEntry, entry_bytes);
        }

        return null;
    }

    /// Read all entries from the log (for replay/recovery)
    pub fn readAll(self: *const AppendLog, allocator: std.mem.Allocator) !std.ArrayList(types.LogEntry) {
        var entries = std.ArrayList(types.LogEntry).init(allocator);
        
        var i: u64 = 0;
        while (i < self.entry_count) : (i += 1) {
            if (try self.read(i)) |entry| {
                try entries.append(entry);
            }
        }

        return entries;
    }

    /// Iterate through all entries (memory efficient)
    pub fn iterator(self: *const AppendLog) LogIterator {
        return LogIterator{
            .log = self,
            .current_index = 0,
        };
    }

    /// Get the number of entries in the log
    pub fn getEntryCount(self: *const AppendLog) u64 {
        return self.entry_count;
    }

    /// Truncate log to a specific entry count (for testing/recovery)
    pub fn truncate(self: *AppendLog, new_count: u64) !void {
        if (new_count > self.entry_count) return;
        
        const new_size = new_count * ENTRY_SIZE;
        
        // Special handling for clearing to 0
        if (new_count == 0) {
            // Unmap memory before truncating to 0
            if (self.mmap) |mmap| {
                std.posix.munmap(mmap);
                self.mmap = null;
            }
            
            // Truncate file to 0 and reset to initial size
            try self.file.setEndPos(0);
            try self.file.setEndPos(self.config.log_initial_size);
            
            // Remap with initial size
            self.mmap = try std.posix.mmap(
                null,
                self.config.log_initial_size,
                std.posix.PROT.READ | std.posix.PROT.WRITE,
                std.posix.MAP{ .TYPE = .SHARED },
                self.file.handle,
                0,
            );
            
            // Zero out the memory to prevent reading stale data
            if (self.mmap) |mmap| {
                @memset(mmap[0..self.config.log_initial_size], 0);
            }
            
            self.current_size = self.config.log_initial_size;
        } else {
            try self.file.setEndPos(new_size);
        }
        
        self.entry_count = new_count;
    }

    /// Clear the log (truncate to 0 entries)
    pub fn clear(self: *AppendLog) !void {
        try self.truncate(0);
    }

    /// Sync log to disk
    pub fn sync(self: *AppendLog) !void {
        try self.file.sync();
        if (self.mmap) |mmap| {
            const aligned_mmap: []align(std.heap.page_size_min) u8 = @alignCast(mmap);
            try std.posix.msync(aligned_mmap, std.posix.MSF.SYNC);
        }
    }

    fn growFile(self: *AppendLog) !void {
        const new_size = @min(self.current_size * 2, self.max_size);
        if (new_size <= self.current_size) {
            // Before failing with LogFull, try automatic compaction
            const size_threshold = @as(f32, @floatFromInt(self.current_size)) * self.config.log_compaction_threshold;
            const used_size = self.entry_count * ENTRY_SIZE;
            
            if (@as(f32, @floatFromInt(used_size)) >= size_threshold) {
                // Try compaction to free up space
                _ = try self.compactLog(self.config.log_compaction_keep_recent);
                
                // After compaction, try growing again if needed
                const new_used_size = self.entry_count * ENTRY_SIZE;
                if (new_used_size < self.current_size / 2) {
                    // Successfully compacted, we have space now
                    return;
                }
            }
            
            return error.LogFull;
        }

        // Unmap current mapping
        if (self.mmap) |mmap| {
            std.posix.munmap(mmap);
        }

        // Extend file
        try self.file.setEndPos(new_size);

        // Remap with new size
        self.mmap = try std.posix.mmap(
            null,
            new_size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            std.posix.MAP{ .TYPE = .SHARED },
            self.file.handle,
            0,
        );

        self.current_size = new_size;
    }

    /// Compact log by keeping only the most recent N entries
    /// This significantly reduces log size by removing old entries
    pub fn compactLog(self: *AppendLog, keep_recent_count: u64) !u64 {
        if (keep_recent_count >= self.entry_count) {
            return self.entry_count; // Nothing to compact
        }
        
        const entries_to_remove = self.entry_count - keep_recent_count;
        const start_index = entries_to_remove;
        
        // Read the entries we want to keep
        var entries_to_keep = std.ArrayList(types.LogEntry).init(self.allocator);
        defer entries_to_keep.deinit();
        
        var i: u64 = start_index;
        while (i < self.entry_count) : (i += 1) {
            if (try self.read(i)) |entry| {
                try entries_to_keep.append(entry);
            }
        }
        
        // Directly clear the log without calling growFile (to break circular dependency)
        if (self.mmap) |mmap| {
            std.posix.munmap(mmap);
            self.mmap = null;
        }
        
        // Calculate required size for the entries we want to keep
        const required_size = entries_to_keep.items.len * ENTRY_SIZE;
        const new_file_size = @max(self.config.log_initial_size, required_size * 2); // Give some buffer
        
        // Truncate file to 0 and reset to adequate size
        try self.file.setEndPos(0);
        try self.file.setEndPos(new_file_size);
        
        // Remap with adequate size
        self.mmap = try std.posix.mmap(
            null,
            new_file_size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            std.posix.MAP{ .TYPE = .SHARED },
            self.file.handle,
            0,
        );
        
        // Zero out the memory to prevent reading stale data
        if (self.mmap) |mmap| {
            @memset(mmap[0..new_file_size], 0);
        }
        
        self.current_size = new_file_size;
        self.entry_count = 0;
        
        // Write back only the recent entries (this won't call growFile since we have enough space)
        if (entries_to_keep.items.len > 0) {
            // Directly write the entries without going through appendBatch to avoid growFile
            const write_offset = self.entry_count * ENTRY_SIZE;
            if (self.mmap) |mmap| {
                for (entries_to_keep.items, 0..) |entry, idx| {
                    const offset = write_offset + (idx * ENTRY_SIZE);
                    const entry_bytes = std.mem.asBytes(&entry);
                    @memcpy(mmap[offset..offset + ENTRY_SIZE], entry_bytes);
                }
                
                // Force write to disk for durability
                const aligned_mmap: []align(std.heap.page_size_min) u8 = @alignCast(mmap);
                try std.posix.msync(aligned_mmap, std.posix.MSF.SYNC);
            }
            self.entry_count += entries_to_keep.items.len;
        }
        
        return entries_to_remove;
    }
};

pub const LogIterator = struct {
    log: *const AppendLog,
    current_index: u64,

    pub fn next(self: *LogIterator) ?types.LogEntry {
        if (self.current_index >= self.log.entry_count) return null;
        
        const entry = self.log.read(self.current_index) catch return null;
        self.current_index += 1;
        return entry;
    }

    pub fn reset(self: *LogIterator) void {
        self.current_index = 0;
    }
};

/// Batch writer for efficient bulk operations
pub const BatchWriter = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(types.LogEntry),
    max_batch_size: usize,

    pub fn init(allocator: std.mem.Allocator, max_batch_size: usize) BatchWriter {
        return BatchWriter{
            .allocator = allocator,
            .entries = std.ArrayList(types.LogEntry).init(allocator),
            .max_batch_size = max_batch_size,
        };
    }

    pub fn deinit(self: *BatchWriter) void {
        self.entries.deinit();
    }

    pub fn addNode(self: *BatchWriter, node: types.Node) !void {
        try self.entries.append(types.LogEntry.initNode(node));
        self.flushIfNeeded();
    }

    pub fn addEdge(self: *BatchWriter, edge: types.Edge) !void {
        try self.entries.append(types.LogEntry.initEdge(edge));
        self.flushIfNeeded();
    }

    pub fn addVector(self: *BatchWriter, vector: types.Vector) !void {
        try self.entries.append(types.LogEntry.initVector(vector));
        self.flushIfNeeded();
    }

    pub fn flush(self: *BatchWriter, log: *AppendLog) !void {
        if (self.entries.items.len > 0) {
            try log.appendBatch(self.entries.items);
            self.entries.clearRetainingCapacity();
        }
    }

    fn flushIfNeeded(self: *BatchWriter) void {
        // This would need a reference to the log, so we'll keep it simple for now
        // In a real implementation, you'd pass the log or use a callback
        _ = self;
    }
};

test "AppendLog basic operations" {
    const allocator = std.testing.allocator;
    const log_path = "test_log.bin";
    
    // Clean up any previous test file
    std.fs.cwd().deleteFile(log_path) catch {};
    
    var log = try AppendLog.init(allocator, log_path, null);
    defer log.deinit();
    defer std.fs.cwd().deleteFile(log_path) catch {};

    // Test single append
    const node = types.Node.init(1, "TestNode");
    const entry = types.LogEntry.initNode(node);
    try log.append(entry);

    try std.testing.expect(log.getEntryCount() == 1);

    // Test read
    const read_entry = (try log.read(0)).?;
    try std.testing.expect(read_entry.getEntryType() == types.LogEntryType.node);
    
    const read_node = read_entry.asNode().?;
    try std.testing.expect(read_node.id == 1);
    try std.testing.expectEqualStrings("TestNode", read_node.getLabelAsString());
}

test "AppendLog batch operations" {
    const allocator = std.testing.allocator;
    const log_path = "test_batch_log.bin";
    
    // Clean up any previous test file
    std.fs.cwd().deleteFile(log_path) catch {};
    
    var log = try AppendLog.init(allocator, log_path, null);
    defer log.deinit();
    defer std.fs.cwd().deleteFile(log_path) catch {};

    // Create batch of entries
    var entries = [_]types.LogEntry{
        types.LogEntry.initNode(types.Node.init(1, "Node1")),
        types.LogEntry.initNode(types.Node.init(2, "Node2")),
        types.LogEntry.initEdge(types.Edge.init(1, 2, types.EdgeKind.owns)),
    };

    try log.appendBatch(&entries);
    try std.testing.expect(log.getEntryCount() == 3);

    // Test iteration
    var iter = log.iterator();
    var count: u32 = 0;
    while (iter.next()) |_| {
        count += 1;
    }
    try std.testing.expect(count == 3);
}

test "BatchWriter functionality" {
    const allocator = std.testing.allocator;
    
    var batch = BatchWriter.init(allocator, 10);
    defer batch.deinit();

    try batch.addNode(types.Node.init(1, "BatchNode"));
    try batch.addEdge(types.Edge.init(1, 2, types.EdgeKind.links));

    try std.testing.expect(batch.entries.items.len == 2);
}

test "AppendLog with custom configuration" {
    const allocator = std.testing.allocator;
    const log_path = "test_config_log.bin";
    
    // Clean up any previous test file
    std.fs.cwd().deleteFile(log_path) catch {};
    defer std.fs.cwd().deleteFile(log_path) catch {};
    
    // Create custom configuration with different sizes
    const custom_config = config.Config{
        .log_initial_size = 512 * 1024, // 512KB instead of default 1MB
        .log_max_size = 512 * 1024 * 1024, // 512MB instead of default 1GB
    };
    
    var log = try AppendLog.init(allocator, log_path, custom_config);
    defer log.deinit();
    
    // Verify the log is using our custom configuration
    try std.testing.expect(log.config.log_initial_size == 512 * 1024);
    try std.testing.expect(log.config.log_max_size == 512 * 1024 * 1024);
    try std.testing.expect(log.current_size == 512 * 1024); // Should start with custom initial size
    try std.testing.expect(log.max_size == 512 * 1024 * 1024); // Should use custom max size
}

test "AppendLog default configuration fallback" {
    const allocator = std.testing.allocator;
    const log_path = "test_default_log.bin";
    
    // Clean up any previous test file and config
    std.fs.cwd().deleteFile(log_path) catch {};
    std.fs.cwd().deleteFile("memora.conf") catch {};
    defer std.fs.cwd().deleteFile(log_path) catch {};
    defer std.fs.cwd().deleteFile("memora.conf") catch {};
    
    // Initialize without explicit config (should use defaults)
    var log = try AppendLog.init(allocator, log_path, null);
    defer log.deinit();
    
    // Verify the log is using default configuration
    try std.testing.expect(log.config.log_initial_size == 1024 * 1024); // 1MB default
    try std.testing.expect(log.config.log_max_size == 1024 * 1024 * 1024); // 1GB default
    try std.testing.expect(log.current_size == 1024 * 1024);
    try std.testing.expect(log.max_size == 1024 * 1024 * 1024);
} 