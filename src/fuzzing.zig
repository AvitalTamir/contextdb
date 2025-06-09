const std = @import("std");
const testing = std.testing;
const contextdb = @import("main.zig");
const types = @import("types.zig");
const raft = @import("raft.zig");

// =============================================================================
// Finite PRNG - Core of TigerBeetle-Inspired Fuzzing
// =============================================================================

/// Finite Random Number Generator that consumes a fixed amount of entropy
/// This allows for reproducible, minimizable test cases
pub const FiniteRng = struct {
    entropy: []const u8,
    position: usize,
    
    pub fn init(entropy: []const u8) FiniteRng {
        return FiniteRng{
            .entropy = entropy,
            .position = 0,
        };
    }
    
    pub fn hasEntropy(self: *const FiniteRng) bool {
        return self.position < self.entropy.len;
    }
    
    pub fn remainingEntropy(self: *const FiniteRng) usize {
        return self.entropy.len - self.position;
    }
    
    pub fn randomU8(self: *FiniteRng) error{OutOfEntropy}!u8 {
        if (self.position >= self.entropy.len) return error.OutOfEntropy;
        const result = self.entropy[self.position];
        self.position += 1;
        return result;
    }
    
    pub fn randomBool(self: *FiniteRng) error{OutOfEntropy}!bool {
        return (try self.randomU8()) % 2 == 0;
    }
    
    pub fn randomU64(self: *FiniteRng) error{OutOfEntropy}!u64 {
        var result: u64 = 0;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            result |= (@as(u64, try self.randomU8()) << @intCast(i * 8));
        }
        return result;
    }
    
    pub fn randomF32(self: *FiniteRng) error{OutOfEntropy}!f32 {
        const bytes = try self.randomU32();
        return @as(f32, @bitCast(bytes)) / @as(f32, @floatFromInt(std.math.maxInt(u32)));
    }
    
    pub fn randomU32(self: *FiniteRng) error{OutOfEntropy}!u32 {
        var result: u32 = 0;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            result |= (@as(u32, try self.randomU8()) << @intCast(i * 8));
        }
        return result;
    }
    
    pub fn randomUsize(self: *FiniteRng, max: usize) error{OutOfEntropy}!usize {
        if (max == 0) return 0;
        const bytes_needed = (@bitSizeOf(usize) + 7) / 8;
        var result: usize = 0;
        var i: usize = 0;
        while (i < bytes_needed) : (i += 1) {
            result |= (@as(usize, try self.randomU8()) << @intCast(i * 8));
        }
        return result % max;
    }
    
    pub fn randomChoice(self: *FiniteRng, comptime T: type, choices: []const T) error{OutOfEntropy}!T {
        if (choices.len == 0) return error.OutOfEntropy;
        const index = try self.randomUsize(choices.len);
        return choices[index];
    }
    
    pub fn randomString(self: *FiniteRng, buffer: []u8, max_len: usize) error{OutOfEntropy}![]u8 {
        const len = @min(try self.randomUsize(max_len + 1), buffer.len);
        var i: usize = 0;
        while (i < len) : (i += 1) {
            // Generate printable ASCII characters
            buffer[i] = @as(u8, @intCast(32 + (try self.randomU8()) % 95));
        }
        return buffer[0..len];
    }
};

// =============================================================================
// Fuzz Test Configuration and Seed Management
// =============================================================================

/// Configuration for fuzzing behavior
pub const FuzzConfig = struct {
    /// Minimum entropy bytes to use
    min_entropy: u32 = 16,
    /// Maximum entropy bytes to use
    max_entropy: u32 = 4096,
    /// Timeout for each test iteration in nanoseconds
    timeout_ns: u64 = 30_000_000_000, // 30 seconds
    /// Whether to enable deterministic mode
    deterministic: bool = true,
    /// Whether to save interesting test cases
    save_cases: bool = true,
    /// Directory to save cases to
    save_dir: []const u8 = "fuzz_cases",
};

/// Combines length and PRNG seed into a single u64 for reproducibility
pub const FuzzSeed = struct {
    seed: u64,
    
    pub fn init(length: u32, prng_seed: u32) FuzzSeed {
        return FuzzSeed{
            .seed = (@as(u64, length) << 32) | @as(u64, prng_seed),
        };
    }
    
    pub fn getLength(self: FuzzSeed) u32 {
        return @as(u32, @intCast(self.seed >> 32));
    }
    
    pub fn getPrngSeed(self: FuzzSeed) u32 {
        return @as(u32, @intCast(self.seed & 0xFFFFFFFF));
    }
    
    pub fn generateEntropy(self: FuzzSeed, allocator: std.mem.Allocator) ![]u8 {
        const length = self.getLength();
        const prng_seed = self.getPrngSeed();
        
        const entropy = try allocator.alloc(u8, length);
        var prng = std.Random.DefaultPrng.init(prng_seed);
        var random = prng.random();
        
        for (entropy) |*byte| {
            byte.* = random.int(u8);
        }
        
        return entropy;
    }
};

// =============================================================================
// Structured Data Generation
// =============================================================================

/// Generate random nodes using finite entropy
pub fn generateRandomNode(frng: *FiniteRng, node_id: u64) error{OutOfEntropy}!types.Node {
    var label_buffer: [32]u8 = [_]u8{0} ** 32;
    const label = try frng.randomString(&label_buffer, 31);
    
    var node = types.Node.init(node_id, "");
    @memcpy(node.label[0..label.len], label);
    
    return node;
}

/// Generate random edges using finite entropy
pub fn generateRandomEdge(frng: *FiniteRng, max_node_id: u64) error{OutOfEntropy}!types.Edge {
    const from = try frng.randomUsize(@intCast(max_node_id + 1));
    const to = try frng.randomUsize(@intCast(max_node_id + 1));
    
    const edge_kinds = [_]types.EdgeKind{ .owns, .links, .related, .child_of, .similar_to };
    const kind = try frng.randomChoice(types.EdgeKind, &edge_kinds);
    
    return types.Edge.init(@intCast(from), @intCast(to), kind);
}

/// Generate random vectors using finite entropy
pub fn generateRandomVector(frng: *FiniteRng, vector_id: u64) error{OutOfEntropy}!types.Vector {
    var dims: [128]f32 = undefined;
    
    for (&dims) |*dim| {
        dim.* = (try frng.randomF32()) * 2.0 - 1.0; // Range [-1, 1]
    }
    
    // Normalize the vector
    var magnitude: f32 = 0.0;
    for (dims) |dim| {
        magnitude += dim * dim;
    }
    magnitude = @sqrt(magnitude);
    
    if (magnitude > 0.0) {
        for (&dims) |*dim| {
            dim.* /= magnitude;
        }
    }
    
    return types.Vector.init(vector_id, &dims);
}

/// Generate a random database operation
pub const DatabaseOperation = union(enum) {
    insert_node: types.Node,
    insert_edge: types.Edge,
    insert_vector: types.Vector,
    query_related: struct { node_id: u64, depth: u8 },
    query_similar: struct { vector_id: u64, k: u8 },
    query_hybrid: struct { node_id: u64, depth: u8, k: u8 },
    create_snapshot: void,
};

pub fn generateRandomOperation(frng: *FiniteRng, max_existing_id: u64) error{OutOfEntropy}!DatabaseOperation {
    const operation_types = [_]u8{ 0, 1, 2, 3, 4, 5, 6 };
    const op_type = try frng.randomChoice(u8, &operation_types);
    
    return switch (op_type) {
        0 => DatabaseOperation{ .insert_node = try generateRandomNode(frng, max_existing_id + 1) },
        1 => DatabaseOperation{ .insert_edge = try generateRandomEdge(frng, max_existing_id) },
        2 => DatabaseOperation{ .insert_vector = try generateRandomVector(frng, max_existing_id + 1) },
        3 => DatabaseOperation{ .query_related = .{
            .node_id = try frng.randomUsize(@intCast(max_existing_id + 1)),
            .depth = @as(u8, @intCast(1 + try frng.randomUsize(5))), // 1-5
        }},
        4 => DatabaseOperation{ .query_similar = .{
            .vector_id = try frng.randomUsize(@intCast(max_existing_id + 1)),
            .k = @as(u8, @intCast(1 + try frng.randomUsize(20))), // 1-20
        }},
        5 => DatabaseOperation{ .query_hybrid = .{
            .node_id = try frng.randomUsize(@intCast(max_existing_id + 1)),
            .depth = @as(u8, @intCast(1 + try frng.randomUsize(4))), // 1-4
            .k = @as(u8, @intCast(1 + try frng.randomUsize(10))), // 1-10
        }},
        6 => DatabaseOperation{ .create_snapshot = {} },
        else => unreachable,
    };
}

// =============================================================================
// Distributed System Fuzzing - Interactive Simulation
// =============================================================================

/// Network simulation for distributed fuzzing
pub const NetworkSimulator = struct {
    const Message = struct {
        src: u8,
        dst: u8,
        msg_type: raft.MessageType,
        payload: []u8,
        delay_remaining: u32, // Simulated network delay
    };
    
    messages: std.ArrayList(Message),
    allocator: std.mem.Allocator,
    packet_loss_rate: f32,
    delay_range: struct { min: u32, max: u32 },
    
    pub fn init(allocator: std.mem.Allocator) NetworkSimulator {
        return NetworkSimulator{
            .messages = std.ArrayList(Message).init(allocator),
            .allocator = allocator,
            .packet_loss_rate = 0.05, // 5% packet loss
            .delay_range = .{ .min = 1, .max = 50 }, // 1-50 ticks delay
        };
    }
    
    pub fn deinit(self: *NetworkSimulator) void {
        // Free all message payloads
        for (self.messages.items) |message| {
            self.allocator.free(message.payload);
        }
        self.messages.deinit();
    }
    
    pub fn sendMessage(
        self: *NetworkSimulator,
        frng: *FiniteRng,
        src: u8,
        dst: u8,
        msg_type: raft.MessageType,
        payload: []const u8,
    ) !void {
        // Simulate packet loss
        if (frng.randomF32() catch 0.0 < self.packet_loss_rate) {
            return; // Packet dropped
        }
        
        // Clone payload
        const cloned_payload = try self.allocator.dupe(u8, payload);
        
        // Add random network delay
        const delay = self.delay_range.min + 
            (frng.randomUsize(self.delay_range.max - self.delay_range.min + 1) catch 0);
        
        try self.messages.append(Message{
            .src = src,
            .dst = dst,
            .msg_type = msg_type,
            .payload = cloned_payload,
            .delay_remaining = @intCast(delay),
        });
    }
    
    pub fn tick(self: *NetworkSimulator) !?Message {
        // Decrement delays and find a message to deliver
        var i: usize = 0;
        while (i < self.messages.items.len) {
            self.messages.items[i].delay_remaining -= 1;
            if (self.messages.items[i].delay_remaining == 0) {
                return self.messages.swapRemove(i);
            }
            i += 1;
        }
        return null;
    }
    
    pub fn pendingMessages(self: *const NetworkSimulator) usize {
        return self.messages.items.len;
    }
};

/// Predicate-based test specification for distributed systems
pub const TestPredicate = struct {
    pub const PredicateType = enum {
        leader_elected,
        nodes_converged,
        minority_partitioned,
        message_type_blocked,
        log_length_reached,
    };
    
    predicate_type: PredicateType,
    parameters: union {
        leader_id: u8,
        converged_term: u64,
        partitioned_nodes: []const u8,
        blocked_message_type: raft.MessageType,
        target_log_length: usize,
    },
    
    pub fn checkLeaderElected(leader_id: u8) TestPredicate {
        return TestPredicate{
            .predicate_type = .leader_elected,
            .parameters = .{ .leader_id = leader_id },
        };
    }
    
    pub fn checkNodesConverged(term: u64) TestPredicate {
        return TestPredicate{
            .predicate_type = .nodes_converged,
            .parameters = .{ .converged_term = term },
        };
    }
    
    pub fn checkMinorityPartitioned(nodes: []const u8) TestPredicate {
        return TestPredicate{
            .predicate_type = .minority_partitioned,
            .parameters = .{ .partitioned_nodes = nodes },
        };
    }
};

/// Scenario for distributed testing - sequence of predicates
pub const DistributedScenario = struct {
    predicates: []const TestPredicate,
    name: []const u8,
    max_ticks: u32,
    
    pub fn init(name: []const u8, predicates: []const TestPredicate, max_ticks: u32) DistributedScenario {
        return DistributedScenario{
            .predicates = predicates,
            .name = name,
            .max_ticks = max_ticks,
        };
    }
};

// =============================================================================
// Fuzz Test Runner and Framework
// =============================================================================

/// Result of a fuzz test execution
pub const FuzzResult = struct {
    success: bool,
    error_message: ?[]const u8,
    operations_completed: usize,
    entropy_consumed: usize,
    duration_ns: u64,
    
    pub fn success_result(ops: usize, entropy: usize, duration: u64) FuzzResult {
        return FuzzResult{
            .success = true,
            .error_message = null,
            .operations_completed = ops,
            .entropy_consumed = entropy,
            .duration_ns = duration,
        };
    }
    
    pub fn failure_result(msg: []const u8, ops: usize, entropy: usize, duration: u64) FuzzResult {
        return FuzzResult{
            .success = false,
            .error_message = msg,
            .operations_completed = ops,
            .entropy_consumed = entropy,
            .duration_ns = duration,
        };
    }
};

/// Main fuzzing framework
pub const FuzzFramework = struct {
    allocator: std.mem.Allocator,
    config: FuzzConfig,
    
    pub fn init(allocator: std.mem.Allocator, config: FuzzConfig) FuzzFramework {
        return FuzzFramework{
            .allocator = allocator,
            .config = config,
        };
    }
    
    /// Run a single fuzz test with given seed
    pub fn runSingleNodeTest(self: *FuzzFramework, seed: FuzzSeed) !FuzzResult {
        const start_time = std.time.nanoTimestamp();
        
        // Generate entropy
        const entropy = try seed.generateEntropy(self.allocator);
        defer self.allocator.free(entropy);
        
        var frng = FiniteRng.init(entropy);
        
        // Clean up test data
        const test_dir = "fuzz_test_data";
        std.fs.cwd().deleteTree(test_dir) catch {};
        defer std.fs.cwd().deleteTree(test_dir) catch {};
        
        // Initialize database
        const db_config = contextdb.ContextDBConfig{
            .data_path = test_dir,
            .enable_persistent_indexes = true,
        };
        
        var db = contextdb.ContextDB.init(self.allocator, db_config, null) catch {
            const duration = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));
            return FuzzResult.failure_result(
                "Failed to initialize database",
                0,
                frng.position,
                duration
            );
        };
        defer db.deinit();
        
        var operations_completed: usize = 0;
        var max_id: u64 = 0;
        
        // Execute random operations until entropy is exhausted
        while (frng.hasEntropy()) {
            // Check timeout
            const current_time = std.time.nanoTimestamp();
            if (@as(u64, @intCast(current_time - start_time)) > self.config.timeout_ns) {
                break;
            }
            
            const operation = generateRandomOperation(&frng, max_id) catch break;
            
            switch (operation) {
                .insert_node => |node| {
                    db.insertNode(node) catch {
                        const duration = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));
                        return FuzzResult.failure_result(
                            "Insert node error",
                            operations_completed,
                            frng.position,
                            duration
                        );
                    };
                    max_id = @max(max_id, node.id);
                },
                .insert_edge => |edge| {
                    db.insertEdge(edge) catch |err| {
                        // Ignore edges to non-existent nodes
                        if (err != error.NodeNotFound) {
                            const duration = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));
                            return FuzzResult.failure_result(
                                "Insert edge error",
                                operations_completed,
                                frng.position,
                                duration
                            );
                        }
                    };
                },
                .insert_vector => |vector| {
                    db.insertVector(vector) catch {
                        const duration = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));
                        return FuzzResult.failure_result(
                            "Insert vector error",
                            operations_completed,
                            frng.position,
                            duration
                        );
                    };
                    max_id = @max(max_id, vector.id);
                },
                .query_related => |query| {
                    const result = db.queryRelated(@intCast(query.node_id), query.depth) catch |err| {
                        // Ignore queries for non-existent nodes
                        if (err != error.NodeNotFound) {
                            const duration = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));
                            return FuzzResult.failure_result(
                                "Query related error",
                                operations_completed,
                                frng.position,
                                duration
                            );
                        }
                        continue;
                    };
                    result.deinit();
                },
                .query_similar => |query| {
                    const result = db.querySimilar(@intCast(query.vector_id), query.k) catch |err| {
                        // Ignore queries for non-existent vectors
                        if (err != error.VectorNotFound) {
                            const duration = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));
                            return FuzzResult.failure_result(
                                "Query similar error",
                                operations_completed,
                                frng.position,
                                duration
                            );
                        }
                        continue;
                    };
                    result.deinit();
                },
                .query_hybrid => |query| {
                    var result = db.queryHybrid(@intCast(query.node_id), query.depth, query.k) catch |err| {
                        // Ignore queries for non-existent nodes
                        if (err != error.NodeNotFound) {
                            const duration = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));
                            return FuzzResult.failure_result(
                                "Query hybrid error",
                                operations_completed,
                                frng.position,
                                duration
                            );
                        }
                        continue;
                    };
                    result.deinit();
                },
                .create_snapshot => {
                    var snapshot_info = db.createSnapshot() catch {
                        const duration = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));
                        return FuzzResult.failure_result(
                            "Create snapshot error",
                            operations_completed,
                            frng.position,
                            duration
                        );
                    };
                    snapshot_info.deinit();
                },
            }
            
            operations_completed += 1;
        }
        
        const duration = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));
        return FuzzResult.success_result(operations_completed, frng.position, duration);
    }
    
    /// Run fuzzing for specified number of iterations
    pub fn runCampaign(self: *FuzzFramework, iterations: u32) !void {
        std.debug.print("Starting fuzz campaign with {} iterations...\n", .{iterations});
        
        var successes: u32 = 0;
        var failures: u32 = 0;
        var total_operations: u64 = 0;
        var total_duration_ns: u64 = 0;
        
        var i: u32 = 0;
        while (i < iterations) : (i += 1) {
            // Generate random seed
            var seed_prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.nanoTimestamp())));
            const random = seed_prng.random();
            
            const length = self.config.min_entropy + 
                random.uintLessThan(u32, self.config.max_entropy - self.config.min_entropy);
            const prng_seed = random.int(u32);
            const seed = FuzzSeed.init(length, prng_seed);
            
            const result = try self.runSingleNodeTest(seed);
            
            if (result.success) {
                successes += 1;
            } else {
                failures += 1;
                std.debug.print("FAILURE (seed: {}, length: {}): {s}\n", .{
                    seed.seed, seed.getLength(), result.error_message orelse "Unknown error"
                });
                
                // Save interesting failure case if configured
                if (self.config.save_cases) {
                    self.saveFailureCase(seed, result) catch |err| {
                        std.debug.print("Failed to save failure case: {}\n", .{err});
                    };
                }
            }
            
            total_operations += result.operations_completed;
            total_duration_ns += result.duration_ns;
            
            if ((i + 1) % 100 == 0) {
                std.debug.print("Progress: {}/{} iterations completed\n", .{ i + 1, iterations });
            }
        }
        
        const avg_ops = total_operations / iterations;
        const avg_duration_ms = total_duration_ns / iterations / 1_000_000;
        
        std.debug.print("\nFuzz campaign completed!\n", .{});
        std.debug.print("  Successes: {}\n", .{successes});
        std.debug.print("  Failures: {}\n", .{failures});
        std.debug.print("  Success rate: {d:.1}%\n", .{@as(f64, @floatFromInt(successes)) / @as(f64, @floatFromInt(iterations)) * 100.0});
        std.debug.print("  Average operations per test: {}\n", .{avg_ops});
        std.debug.print("  Average duration per test: {}ms\n", .{avg_duration_ms});
    }
    
    fn saveFailureCase(self: *FuzzFramework, seed: FuzzSeed, result: FuzzResult) !void {
        // Create save directory if it doesn't exist
        std.fs.cwd().makeDir(self.config.save_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
        
        // Generate filename
        var filename_buf: [256]u8 = undefined;
        const filename = try std.fmt.bufPrint(&filename_buf, "{s}/failure_{}.txt", .{
            self.config.save_dir, seed.seed
        });
        
        // Write failure case
        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();
        
        const writer = file.writer();
        try writer.print("Seed: {}\n", .{seed.seed});
        try writer.print("Length: {}\n", .{seed.getLength()});
        try writer.print("PRNG Seed: {}\n", .{seed.getPrngSeed()});
        try writer.print("Operations completed: {}\n", .{result.operations_completed});
        try writer.print("Entropy consumed: {}\n", .{result.entropy_consumed});
        try writer.print("Duration (ns): {}\n", .{result.duration_ns});
        try writer.print("Error: {s}\n", .{result.error_message orelse "Unknown"});
    }
};

// =============================================================================
// Tests for the Fuzzing Framework
// =============================================================================

test "FiniteRng basic functionality" {
    const entropy = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    var frng = FiniteRng.init(&entropy);
    
    try testing.expect(frng.hasEntropy());
    try testing.expect(frng.remainingEntropy() == 4);
    
    const val1 = try frng.randomU8();
    try testing.expect(val1 == 0x12);
    try testing.expect(frng.remainingEntropy() == 3);
    
    const val2 = try frng.randomU8();
    try testing.expect(val2 == 0x34);
    
    // Test that it runs out of entropy
    _ = try frng.randomU8();
    _ = try frng.randomU8();
    try testing.expect(!frng.hasEntropy());
    
    const result = frng.randomU8();
    try testing.expectError(error.OutOfEntropy, result);
}

test "FuzzSeed generation and entropy" {
    const seed = FuzzSeed.init(16, 42);
    
    try testing.expect(seed.getLength() == 16);
    try testing.expect(seed.getPrngSeed() == 42);
    
    const entropy = try seed.generateEntropy(testing.allocator);
    defer testing.allocator.free(entropy);
    
    try testing.expect(entropy.len == 16);
    
    // Test determinism - same seed should generate same entropy
    const entropy2 = try seed.generateEntropy(testing.allocator);
    defer testing.allocator.free(entropy2);
    
    try testing.expect(std.mem.eql(u8, entropy, entropy2));
}

test "Structured data generation" {
    const entropy = [_]u8{0x42} ** 64;
    var frng = FiniteRng.init(&entropy);
    
    // Test node generation
    const node = try generateRandomNode(&frng, 123);
    try testing.expect(node.id == 123);
    try testing.expect(node.label.len > 0);
    
    // Reset entropy
    frng = FiniteRng.init(&entropy);
    
    // Test edge generation
    const edge = try generateRandomEdge(&frng, 10);
    try testing.expect(edge.from <= 10);
    try testing.expect(edge.to <= 10);
    
    // Reset entropy
    frng = FiniteRng.init(&entropy);
    
    // Test vector generation
    const vector = try generateRandomVector(&frng, 456);
    try testing.expect(vector.id == 456);
    try testing.expect(vector.dims.len == 128);
    
    // Verify vector is normalized
    var magnitude: f32 = 0.0;
    for (vector.dims) |dim| {
        magnitude += dim * dim;
    }
    magnitude = @sqrt(magnitude);
    try testing.expect(@abs(magnitude - 1.0) < 0.01); // Should be approximately 1.0
}

test "Fuzz framework basic test" {
    const config = FuzzConfig{
        .min_entropy = 16,
        .max_entropy = 64,
        .timeout_ns = 1_000_000_000, // 1 second
        .save_cases = false,
    };
    
    var framework = FuzzFramework.init(testing.allocator, config);
    
    // Test a single run
    const seed = FuzzSeed.init(32, 12345);
    const result = try framework.runSingleNodeTest(seed);
    
    // Should either succeed or fail gracefully
    if (!result.success) {
        std.debug.print("Test failed (expected): {s}\n", .{result.error_message orelse "Unknown"});
    }
    
    try testing.expect(result.duration_ns > 0);
} 