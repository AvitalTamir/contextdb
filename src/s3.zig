const std = @import("std");

const S3Error = error{
    CommandFailed,
    S3UploadFailed,
    S3DownloadFailed,
    S3DeleteFailed,
    S3ListFailed,
    S3SyncFailed,
};

/// Simple S3 integration using AWS CLI subprocess calls
/// In production, you'd use a proper S3 client library
pub const S3Client = struct {
    allocator: std.mem.Allocator,
    bucket_name: []const u8,
    region: []const u8,

    pub fn init(allocator: std.mem.Allocator, bucket_name: []const u8, region: []const u8) S3Client {
        return S3Client{
            .allocator = allocator,
            .bucket_name = bucket_name,
            .region = region,
        };
    }

    /// Upload a local file to S3
    pub fn uploadFile(self: *const S3Client, local_path: []const u8, s3_key: []const u8) !void {
        const s3_url = try std.fmt.allocPrint(self.allocator, "s3://{s}/{s}", .{ self.bucket_name, s3_key });
        defer self.allocator.free(s3_url);

        const cmd = try std.fmt.allocPrint(self.allocator, "aws s3 cp \"{s}\" \"{s}\" --region {s}", .{ local_path, s3_url, self.region });
        defer self.allocator.free(cmd);

        var process = std.process.Child.init(&[_][]const u8{ "sh", "-c", cmd }, self.allocator);
        process.stdout_behavior = .Ignore;
        process.stderr_behavior = .Ignore;

        const result = try process.spawnAndWait();
        if (result != .Exited or result.Exited != 0) {
            return S3Error.S3UploadFailed;
        }
    }

    /// Download a file from S3 to local path
    pub fn downloadFile(self: *const S3Client, s3_key: []const u8, local_path: []const u8) !void {
        const s3_url = try std.fmt.allocPrint(self.allocator, "s3://{s}/{s}", .{ self.bucket_name, s3_key });
        defer self.allocator.free(s3_url);

        const cmd = try std.fmt.allocPrint(self.allocator, "aws s3 cp \"{s}\" \"{s}\" --region {s}", .{ s3_url, local_path, self.region });
        defer self.allocator.free(cmd);

        var process = std.process.Child.init(&[_][]const u8{ "sh", "-c", cmd }, self.allocator);
        process.stdout_behavior = .Ignore;
        process.stderr_behavior = .Ignore;

        const result = try process.spawnAndWait();
        if (result != .Exited or result.Exited != 0) {
            return S3Error.S3DownloadFailed;
        }
    }

    /// Upload a directory to S3 recursively
    pub fn uploadDirectory(self: *const S3Client, local_dir: []const u8, s3_prefix: []const u8) !void {
        const s3_url = try std.fmt.allocPrint(self.allocator, "s3://{s}/{s}", .{ self.bucket_name, s3_prefix });
        defer self.allocator.free(s3_url);

        const cmd = try std.fmt.allocPrint(self.allocator, "aws s3 sync \"{s}\" \"{s}\" --region {s}", .{ local_dir, s3_url, self.region });
        defer self.allocator.free(cmd);

        var process = std.process.Child.init(&[_][]const u8{ "sh", "-c", cmd }, self.allocator);
        process.stdout_behavior = .Ignore;
        process.stderr_behavior = .Ignore;

        const result = try process.spawnAndWait();
        if (result != .Exited or result.Exited != 0) {
            return S3Error.S3SyncFailed;
        }
    }

    /// Download a directory from S3 recursively
    pub fn downloadDirectory(self: *const S3Client, s3_prefix: []const u8, local_dir: []const u8) !void {
        const s3_url = try std.fmt.allocPrint(self.allocator, "s3://{s}/{s}", .{ self.bucket_name, s3_prefix });
        defer self.allocator.free(s3_url);

        const cmd = try std.fmt.allocPrint(self.allocator, "aws s3 sync \"{s}\" \"{s}\" --region {s}", .{ s3_url, local_dir, self.region });
        defer self.allocator.free(cmd);

        var process = std.process.Child.init(&[_][]const u8{ "sh", "-c", cmd }, self.allocator);
        process.stdout_behavior = .Ignore;
        process.stderr_behavior = .Ignore;

        const result = try process.spawnAndWait();
        if (result != .Exited or result.Exited != 0) {
            return S3Error.S3SyncFailed;
        }
    }

    /// List objects in S3 bucket with prefix
    pub fn listObjects(self: *const S3Client, prefix: []const u8) !std.ArrayList([]const u8) {
        const s3_url = try std.fmt.allocPrint(self.allocator, "s3://{s}/{s}", .{ self.bucket_name, prefix });
        defer self.allocator.free(s3_url);

        const cmd = try std.fmt.allocPrint(self.allocator, "aws s3 ls \"{s}\" --region {s}", .{ s3_url, self.region });
        defer self.allocator.free(cmd);

        var process = std.process.Child.init(&[_][]const u8{ "sh", "-c", cmd }, self.allocator);
        process.stdout_behavior = .Pipe;
        process.stderr_behavior = .Ignore;

        try process.spawn();
        
        var stdout_buffer: [64 * 1024]u8 = undefined;
        const stdout_len = try process.stdout.?.readAll(&stdout_buffer);
        
        const result = try process.wait();
        if (result != .Exited or result.Exited != 0) {
            return S3Error.S3ListFailed;
        }

        var objects = std.ArrayList([]const u8).init(self.allocator);
        var lines = std.mem.splitScalar(u8, stdout_buffer[0..stdout_len], '\n');
        
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            
            // Parse AWS CLI output format: "2023-01-01 12:00:00       1234 filename"
            var parts = std.mem.splitScalar(u8, line, ' ');
            var part_count: u8 = 0;
            var filename: []const u8 = "";
            
            while (parts.next()) |part| {
                if (part.len == 0) continue;
                part_count += 1;
                if (part_count == 4) {
                    filename = part;
                    break;
                }
            }
            
            if (filename.len > 0) {
                try objects.append(try self.allocator.dupe(u8, filename));
            }
        }

        return objects;
    }

    /// Check if AWS CLI is available
    pub fn checkAwsCli(self: *const S3Client) !bool {
        var process = std.process.Child.init(&[_][]const u8{ "aws", "--version" }, self.allocator);
        process.stdout_behavior = .Ignore;
        process.stderr_behavior = .Ignore;

        const result = try process.spawnAndWait();
        return result == .Exited and result.Exited == 0;
    }

    /// Delete an object from S3
    pub fn deleteObject(self: *const S3Client, s3_key: []const u8) !void {
        const s3_url = try std.fmt.allocPrint(self.allocator, "s3://{s}/{s}", .{ self.bucket_name, s3_key });
        defer self.allocator.free(s3_url);

        const cmd = try std.fmt.allocPrint(self.allocator, "aws s3 rm \"{s}\" --region {s}", .{ s3_url, self.region });
        defer self.allocator.free(cmd);

        var process = std.process.Child.init(&[_][]const u8{ "sh", "-c", cmd }, self.allocator);
        process.stdout_behavior = .Ignore;
        process.stderr_behavior = .Ignore;

        const result = try process.spawnAndWait();
        if (result != .Exited or result.Exited != 0) {
            return S3Error.S3DeleteFailed;
        }
    }

    fn executeCommand(self: *S3Client, cmd: []const u8) !std.ArrayList(u8) {
        var process = std.process.Child.init(&[_][]const u8{ "sh", "-c", cmd }, self.allocator);
        process.stdout_behavior = .Pipe;
        process.stderr_behavior = .Pipe;

        try process.spawn();

        var stdout = std.ArrayList(u8).init(self.allocator);
        var stderr = std.ArrayList(u8).init(self.allocator);
        defer stderr.deinit();

        try process.collectOutput(&stdout, &stderr, 1024 * 1024);
        const exit_status = try process.wait();

        if (exit_status != .Exited or exit_status.Exited != 0) {
            self.allocator.free(stdout.items);
            stdout.deinit();
            return S3Error.CommandFailed;
        }

        return stdout;
    }
};

/// High-level S3 operations for ContextDB snapshots
pub const S3SnapshotSync = struct {
    s3_client: S3Client,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, bucket_name: []const u8, region: []const u8) S3SnapshotSync {
        return S3SnapshotSync{
            .s3_client = S3Client.init(allocator, bucket_name, region),
            .allocator = allocator,
        };
    }

    /// Upload entire ContextDB directory to S3
    pub fn uploadDatabase(self: *const S3SnapshotSync, local_db_path: []const u8, s3_prefix: []const u8) !void {
        try self.s3_client.uploadDirectory(local_db_path, s3_prefix);
    }

    /// Download entire ContextDB directory from S3
    pub fn downloadDatabase(self: *const S3SnapshotSync, s3_prefix: []const u8, local_db_path: []const u8) !void {
        // Ensure local directory exists
        try std.fs.cwd().makePath(local_db_path);
        try self.s3_client.downloadDirectory(s3_prefix, local_db_path);
    }

    /// Upload specific snapshot to S3
    pub fn uploadSnapshot(self: *const S3SnapshotSync, local_db_path: []const u8, snapshot_id: u64, s3_prefix: []const u8) !void {
        // Upload metadata file
        const metadata_filename = try std.fmt.allocPrint(self.allocator, "snapshot-{:06}.json", .{snapshot_id});
        defer self.allocator.free(metadata_filename);
        
        const local_metadata_path = try std.fs.path.join(self.allocator, &[_][]const u8{ local_db_path, "metadata", metadata_filename });
        defer self.allocator.free(local_metadata_path);
        
        const s3_metadata_key = try std.fs.path.join(self.allocator, &[_][]const u8{ s3_prefix, "metadata", metadata_filename });
        defer self.allocator.free(s3_metadata_key);
        
        try self.s3_client.uploadFile(local_metadata_path, s3_metadata_key);

        // Upload associated data files
        // This would require reading the metadata file to find associated files
        // For simplicity, we'll sync the entire directory
        try self.uploadDatabase(local_db_path, s3_prefix);
    }

    /// Download specific snapshot from S3
    pub fn downloadSnapshot(self: *const S3SnapshotSync, s3_prefix: []const u8, snapshot_id: u64, local_db_path: []const u8) !void {
        // Download metadata file first
        const metadata_filename = try std.fmt.allocPrint(self.allocator, "snapshot-{:06}.json", .{snapshot_id});
        defer self.allocator.free(metadata_filename);
        
        const s3_metadata_key = try std.fs.path.join(self.allocator, &[_][]const u8{ s3_prefix, "metadata", metadata_filename });
        defer self.allocator.free(s3_metadata_key);
        
        const local_metadata_path = try std.fs.path.join(self.allocator, &[_][]const u8{ local_db_path, "metadata", metadata_filename });
        defer self.allocator.free(local_metadata_path);
        
        // Ensure local directory structure exists
        if (std.fs.path.dirname(local_metadata_path)) |parent_dir| {
            try std.fs.cwd().makePath(parent_dir);
        }
        
        try self.s3_client.downloadFile(s3_metadata_key, local_metadata_path);
        
        // Download the rest of the database
        try self.downloadDatabase(s3_prefix, local_db_path);
    }

    /// List available snapshots in S3
    pub fn listRemoteSnapshots(self: *const S3SnapshotSync, s3_prefix: []const u8) !std.ArrayList(u64) {
        const metadata_prefix = try std.fs.path.join(self.allocator, &[_][]const u8{ s3_prefix, "metadata/" });
        defer self.allocator.free(metadata_prefix);
        
        const objects = try self.s3_client.listObjects(metadata_prefix);
        defer {
            for (objects.items) |obj| {
                self.allocator.free(obj);
            }
            objects.deinit();
        }

        var snapshots = std.ArrayList(u64).init(self.allocator);
        
        for (objects.items) |obj| {
            if (std.mem.startsWith(u8, obj, "snapshot-") and std.mem.endsWith(u8, obj, ".json")) {
                const id_part = obj[9..15]; // Extract 6-digit ID
                if (std.fmt.parseInt(u64, id_part, 10)) |snapshot_id| {
                    try snapshots.append(snapshot_id);
                } else |_| {
                    // Skip invalid filenames
                }
            }
        }

        // Sort in ascending order
        std.sort.pdq(u64, snapshots.items, {}, std.sort.asc(u64));
        return snapshots;
    }

    /// Clean up old snapshots in S3, keeping only the latest N
    pub fn cleanupRemoteSnapshots(self: *const S3SnapshotSync, s3_prefix: []const u8, keep_count: u32) !u32 {
        const snapshots = try self.listRemoteSnapshots(s3_prefix);
        defer snapshots.deinit();

        if (snapshots.items.len <= keep_count) return 0;

        const delete_count = snapshots.items.len - keep_count;
        var deleted: u32 = 0;

        for (snapshots.items[0..delete_count]) |snapshot_id| {
            if (try self.deleteRemoteSnapshot(s3_prefix, snapshot_id)) {
                deleted += 1;
            }
        }

        return deleted;
    }

    fn deleteRemoteSnapshot(self: *const S3SnapshotSync, s3_prefix: []const u8, snapshot_id: u64) !bool {
        const metadata_filename = try std.fmt.allocPrint(self.allocator, "snapshot-{:06}.json", .{snapshot_id});
        defer self.allocator.free(metadata_filename);
        
        const s3_metadata_key = try std.fs.path.join(self.allocator, &[_][]const u8{ s3_prefix, "metadata", metadata_filename });
        defer self.allocator.free(s3_metadata_key);
        
        // Delete metadata file
        self.s3_client.deleteObject(s3_metadata_key) catch return false;
        
        // Delete associated data files
        // For simplicity, we assume snapshot files follow naming convention
        const vector_filename = try std.fmt.allocPrint(self.allocator, "vec-{:06}.blob", .{snapshot_id});
        defer self.allocator.free(vector_filename);
        
        const node_filename = try std.fmt.allocPrint(self.allocator, "node-{:06}.json", .{snapshot_id});
        defer self.allocator.free(node_filename);
        
        const edge_filename = try std.fmt.allocPrint(self.allocator, "edge-{:06}.json", .{snapshot_id});
        defer self.allocator.free(edge_filename);
        
        // Try to delete data files (ignore errors if they don't exist)
        self.s3_client.deleteObject(try std.fs.path.join(self.allocator, &[_][]const u8{ s3_prefix, "vectors", vector_filename })) catch {};
        self.s3_client.deleteObject(try std.fs.path.join(self.allocator, &[_][]const u8{ s3_prefix, "nodes", node_filename })) catch {};
        self.s3_client.deleteObject(try std.fs.path.join(self.allocator, &[_][]const u8{ s3_prefix, "edges", edge_filename })) catch {};
        
        return true;
    }
};

test "S3Client AWS CLI check" {
    const allocator = std.testing.allocator;
    
    const s3_client = S3Client.init(allocator, "test-bucket", "us-east-1");
    
    // This test will only pass if AWS CLI is installed
    // Skip if not available
    const has_aws_cli = s3_client.checkAwsCli() catch false;
    if (!has_aws_cli) {
        std.debug.print("AWS CLI not available, skipping S3 tests\n", .{});
        return;
    }
    
    try std.testing.expect(has_aws_cli);
} 