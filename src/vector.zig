const std = @import("std");
const types = @import("types.zig");

/// In-memory vector index for similarity search
/// Uses linear search for simplicity, can be upgraded to HNSW/IVF later
pub const VectorIndex = struct {
    allocator: std.mem.Allocator,
    vectors: std.AutoHashMap(u64, types.Vector),
    vector_list: std.ArrayList(types.Vector), // For efficient iteration

    pub fn init(allocator: std.mem.Allocator) VectorIndex {
        return VectorIndex{
            .allocator = allocator,
            .vectors = std.AutoHashMap(u64, types.Vector).init(allocator),
            .vector_list = std.ArrayList(types.Vector).init(allocator),
        };
    }

    pub fn deinit(self: *VectorIndex) void {
        self.vectors.deinit();
        self.vector_list.deinit();
    }

    /// Add a vector to the index
    pub fn addVector(self: *VectorIndex, vector: types.Vector) !void {
        // Add to both hash map and list
        try self.vectors.put(vector.id, vector);
        try self.vector_list.append(vector);
    }

    /// Get a vector by ID
    pub fn getVector(self: *const VectorIndex, vector_id: u64) ?types.Vector {
        return self.vectors.get(vector_id);
    }

    /// Remove a vector by ID
    pub fn removeVector(self: *VectorIndex, vector_id: u64) bool {
        if (self.vectors.fetchRemove(vector_id)) |_| {
            // Also remove from list (linear search)
            for (self.vector_list.items, 0..) |vec, i| {
                if (vec.id == vector_id) {
                    _ = self.vector_list.orderedRemove(i);
                    break;
                }
            }
            return true;
        }
        return false;
    }

    /// Get the number of vectors in the index
    pub fn getVectorCount(self: *const VectorIndex) u32 {
        return @intCast(self.vectors.count());
    }

    /// Get all vector IDs
    pub fn getAllVectorIds(self: *const VectorIndex, allocator: std.mem.Allocator) !std.ArrayList(u64) {
        var ids = std.ArrayList(u64).init(allocator);
        var iter = self.vectors.iterator();
        while (iter.next()) |entry| {
            try ids.append(entry.key_ptr.*);
        }
        return ids;
    }

    /// Clear all vectors
    pub fn clear(self: *VectorIndex) void {
        self.vectors.clearRetainingCapacity();
        self.vector_list.clearRetainingCapacity();
    }
};

/// Vector similarity search engine
pub const VectorSearch = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) VectorSearch {
        return VectorSearch{
            .allocator = allocator,
        };
    }

    /// Find k most similar vectors using cosine similarity
    pub fn querySimilar(self: *const VectorSearch, index: *const VectorIndex, query_vector_id: u64, top_k: u32) !std.ArrayList(types.SimilarityResult) {
        const query_vector = index.getVector(query_vector_id) orelse return error.VectorNotFound;
        return self.querySimilarByVector(index, query_vector, top_k);
    }

    /// Find k most similar vectors given a query vector directly
    pub fn querySimilarByVector(self: *const VectorSearch, index: *const VectorIndex, query_vector: types.Vector, top_k: u32) !std.ArrayList(types.SimilarityResult) {
        var similarities = std.ArrayList(types.SimilarityResult).init(self.allocator);
        
        // Calculate similarity with all vectors
        for (index.vector_list.items) |candidate_vector| {
            if (candidate_vector.id == query_vector.id) continue; // Skip self
            
            const similarity = query_vector.cosineSimilarity(&candidate_vector);
            try similarities.append(types.SimilarityResult{
                .id = candidate_vector.id,
                .similarity = similarity,
            });
        }

        // Sort by similarity (descending)
        std.sort.pdq(types.SimilarityResult, similarities.items, {}, compareByDescendingSimilarity);

        // Keep only top k
        const actual_k = @min(top_k, @as(u32, @intCast(similarities.items.len)));
        if (similarities.items.len > actual_k) {
            similarities.shrinkRetainingCapacity(actual_k);
        }

        return similarities;
    }

    /// Find vectors within a similarity threshold
    pub fn querySimilarityThreshold(self: *const VectorSearch, index: *const VectorIndex, query_vector_id: u64, threshold: f32) !std.ArrayList(types.SimilarityResult) {
        const query_vector = index.getVector(query_vector_id) orelse return error.VectorNotFound;
        
        var results = std.ArrayList(types.SimilarityResult).init(self.allocator);
        
        for (index.vector_list.items) |candidate_vector| {
            if (candidate_vector.id == query_vector_id) continue; // Skip self
            
            const similarity = query_vector.cosineSimilarity(&candidate_vector);
            if (similarity >= threshold) {
                try results.append(types.SimilarityResult{
                    .id = candidate_vector.id,
                    .similarity = similarity,
                });
            }
        }

        // Sort by similarity (descending)
        std.sort.pdq(types.SimilarityResult, results.items, {}, compareByDescendingSimilarity);

        return results;
    }

    /// Batch similarity search for multiple query vectors
    pub fn batchQuerySimilar(self: *const VectorSearch, index: *const VectorIndex, query_vector_ids: []const u64, top_k: u32) !std.ArrayList(std.ArrayList(types.SimilarityResult)) {
        var batch_results = std.ArrayList(std.ArrayList(types.SimilarityResult)).init(self.allocator);
        
        for (query_vector_ids) |query_id| {
            const results = try self.querySimilar(index, query_id, top_k);
            try batch_results.append(results);
        }
        
        return batch_results;
    }

    /// Find the centroid of a set of vectors
    pub fn findCentroid(self: *const VectorSearch, index: *const VectorIndex, vector_ids: []const u64) !?types.Vector {
        _ = self; // unused
        if (vector_ids.len == 0) return null;
        
        var centroid_dims = [_]f32{0.0} ** 128;
        var valid_count: u32 = 0;
        
        for (vector_ids) |vector_id| {
            if (index.getVector(vector_id)) |vector| {
                for (vector.dims, 0..) |dim, i| {
                    centroid_dims[i] += dim;
                }
                valid_count += 1;
            }
        }
        
        if (valid_count == 0) return null;
        
        // Average the dimensions
        for (&centroid_dims) |*dim| {
            dim.* /= @floatFromInt(valid_count);
        }
        
        return types.Vector.init(0, &centroid_dims); // ID 0 for centroid
    }

    /// Calculate distance matrix between vectors
    pub fn calculateDistanceMatrix(self: *const VectorSearch, index: *const VectorIndex, vector_ids: []const u64) !std.ArrayList(std.ArrayList(f32)) {
        var matrix = std.ArrayList(std.ArrayList(f32)).init(self.allocator);
        
        for (vector_ids) |id_i| {
            var row = std.ArrayList(f32).init(self.allocator);
            
            for (vector_ids) |id_j| {
                var distance: f32 = 0.0;
                
                if (id_i == id_j) {
                    distance = 1.0; // Perfect similarity with self
                } else if (index.getVector(id_i)) |vec_i| {
                    if (index.getVector(id_j)) |vec_j| {
                        distance = vec_i.cosineSimilarity(&vec_j);
                    }
                }
                
                try row.append(distance);
            }
            
            try matrix.append(row);
        }
        
        return matrix;
    }

    /// Find k-nearest neighbors and return their statistics
    pub fn getNeighborStatistics(self: *const VectorSearch, index: *const VectorIndex, query_vector_id: u64, k: u32) !VectorStatistics {
        const similar_vectors = try self.querySimilar(index, query_vector_id, k);
        defer similar_vectors.deinit();
        
        if (similar_vectors.items.len == 0) {
            return VectorStatistics{
                .count = 0,
                .mean_similarity = 0.0,
                .max_similarity = 0.0,
                .min_similarity = 0.0,
                .std_deviation = 0.0,
            };
        }
        
        var sum: f32 = 0.0;
        var max_sim: f32 = similar_vectors.items[0].similarity;
        var min_sim: f32 = similar_vectors.items[0].similarity;
        
        for (similar_vectors.items) |result| {
            sum += result.similarity;
            max_sim = @max(max_sim, result.similarity);
            min_sim = @min(min_sim, result.similarity);
        }
        
        const mean = sum / @as(f32, @floatFromInt(similar_vectors.items.len));
        
        // Calculate standard deviation
        var variance_sum: f32 = 0.0;
        for (similar_vectors.items) |result| {
            const diff = result.similarity - mean;
            variance_sum += diff * diff;
        }
        const std_dev = @sqrt(variance_sum / @as(f32, @floatFromInt(similar_vectors.items.len)));
        
        return VectorStatistics{
            .count = @intCast(similar_vectors.items.len),
            .mean_similarity = mean,
            .max_similarity = max_sim,
            .min_similarity = min_sim,
            .std_deviation = std_dev,
        };
    }
};

pub const VectorStatistics = struct {
    count: u32,
    mean_similarity: f32,
    max_similarity: f32,
    min_similarity: f32,
    std_deviation: f32,
};

/// Comparison function for sorting similarity results in descending order
fn compareByDescendingSimilarity(context: void, a: types.SimilarityResult, b: types.SimilarityResult) bool {
    _ = context;
    return a.similarity > b.similarity;
}

/// Vector clustering using k-means (simplified version)
pub const VectorClustering = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) VectorClustering {
        return VectorClustering{
            .allocator = allocator,
        };
    }
    
    /// Simple k-means clustering of vectors
    pub fn kMeansClustering(self: *const VectorClustering, vectors: []const types.Vector, k: u32, max_iterations: u32) !std.ArrayList(Cluster) {
        if (vectors.len == 0 or k == 0) return std.ArrayList(Cluster).init(self.allocator);
        
        var clusters = std.ArrayList(Cluster).init(self.allocator);
        
        // Initialize k clusters with random centroids (deterministic for testing)
        for (0..k) |i| {
            var cluster = Cluster{
                .centroid = vectors[i % vectors.len], // Simple deterministic initialization
                .members = std.ArrayList(u64).init(self.allocator),
            };
            cluster.centroid.id = @intCast(i); // Give cluster ID
            try clusters.append(cluster);
        }
        
        var iteration: u32 = 0;
        while (iteration < max_iterations) : (iteration += 1) {
            // Clear previous assignments
            for (clusters.items) |*cluster| {
                cluster.members.clearRetainingCapacity();
            }
            
            // Assign each vector to the nearest cluster
            for (vectors) |vector| {
                var best_cluster_idx: usize = 0;
                var best_similarity: f32 = -1.0;
                
                for (clusters.items, 0..) |cluster, cluster_idx| {
                    const similarity = vector.cosineSimilarity(&cluster.centroid);
                    if (similarity > best_similarity) {
                        best_similarity = similarity;
                        best_cluster_idx = cluster_idx;
                    }
                }
                
                try clusters.items[best_cluster_idx].members.append(vector.id);
            }
            
            // Update centroids
            for (clusters.items) |*cluster| {
                if (cluster.members.items.len > 0) {
                    cluster.centroid = try self.calculateCentroid(vectors, cluster.members.items);
                }
            }
        }
        
        return clusters;
    }
    
    fn calculateCentroid(self: *const VectorClustering, all_vectors: []const types.Vector, member_ids: []const u64) !types.Vector {
        _ = self;
        var centroid_dims = [_]f32{0.0} ** 128;
        var count: u32 = 0;
        
        for (member_ids) |member_id| {
            for (all_vectors) |vector| {
                if (vector.id == member_id) {
                    for (vector.dims, 0..) |dim, i| {
                        centroid_dims[i] += dim;
                    }
                    count += 1;
                    break;
                }
            }
        }
        
        if (count > 0) {
            for (&centroid_dims) |*dim| {
                dim.* /= @floatFromInt(count);
            }
        }
        
        return types.Vector.init(0, &centroid_dims);
    }
};

pub const Cluster = struct {
    centroid: types.Vector,
    members: std.ArrayList(u64),
    
    pub fn deinit(self: *Cluster) void {
        self.members.deinit();
    }
};

/// HNSW (Hierarchical Navigable Small World) Configuration
pub const HNSWConfig = struct {
    /// Maximum number of connections per node in higher layers
    max_connections: u16 = 16,
    /// Maximum number of connections per node in layer 0
    max_connections_layer0: u32 = 32,
    /// Size of the dynamic candidate list used during construction
    ef_construction: u32 = 200,
    /// Level generation factor (1/ln(2) for exponential decay)
    ml: f32 = 1.0 / @log(2.0),
    /// Seed for deterministic behavior
    seed: u64 = 42,
};

/// HNSW Node representing a vector in the graph
const HNSWNode = struct {
    vector_id: u64,
    layer: u8,
    connections: std.ArrayList(u64), // Connected node IDs

    pub fn init(allocator: std.mem.Allocator, vector_id: u64, layer: u8) HNSWNode {
        return HNSWNode{
            .vector_id = vector_id,
            .layer = layer,
            .connections = std.ArrayList(u64).init(allocator),
        };
    }

    pub fn deinit(self: *HNSWNode) void {
        self.connections.deinit();
    }

    pub fn addConnection(self: *HNSWNode, other_id: u64) !void {
        // Avoid duplicate connections
        for (self.connections.items) |existing_id| {
            if (existing_id == other_id) return;
        }
        try self.connections.append(other_id);
    }

    pub fn removeConnection(self: *HNSWNode, other_id: u64) void {
        for (self.connections.items, 0..) |existing_id, i| {
            if (existing_id == other_id) {
                _ = self.connections.orderedRemove(i);
                return;
            }
        }
    }
};

/// Priority queue element for HNSW search
const SearchCandidate = struct {
    id: u64,
    distance: f32, // Actually negative similarity for max-heap behavior
    
    pub fn lessThan(_: void, a: SearchCandidate, b: SearchCandidate) std.math.Order {
        return std.math.order(a.distance, b.distance);
    }
};

/// HNSW Statistics
pub const HNSWStats = struct {
    num_vectors: u64,
    num_layers: u8,
    entry_point: u64,
    total_connections: u64,
    avg_connections_per_layer: f32,
};

/// Hierarchical Navigable Small World (HNSW) Index
/// High-performance approximate nearest neighbor search
pub const HNSWIndex = struct {
    allocator: std.mem.Allocator,
    config: HNSWConfig,
    
    // Vector storage (ID -> Vector mapping)
    vectors: std.AutoHashMap(u64, types.Vector),
    
    // HNSW graph structure: layer -> (node_id -> HNSWNode)
    layers: std.ArrayList(std.AutoHashMap(u64, HNSWNode)),
    
    // Entry point for search (highest layer)
    entry_point: ?u64,
    
    // Random number generator for deterministic behavior
    prng: std.Random.DefaultPrng,
    
    pub fn init(allocator: std.mem.Allocator, config: HNSWConfig) !HNSWIndex {
        var layers = std.ArrayList(std.AutoHashMap(u64, HNSWNode)).init(allocator);
        
        // Initialize at least one layer (layer 0)
        try layers.append(std.AutoHashMap(u64, HNSWNode).init(allocator));
        
        return HNSWIndex{
            .allocator = allocator,
            .config = config,
            .vectors = std.AutoHashMap(u64, types.Vector).init(allocator),
            .layers = layers,
            .entry_point = null,
            .prng = std.Random.DefaultPrng.init(config.seed),
        };
    }
    
    pub fn deinit(self: *HNSWIndex) void {
        // Clean up all nodes in all layers
        for (self.layers.items) |*layer| {
            var iter = layer.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.deinit();
            }
            layer.deinit();
        }
        self.layers.deinit();
        self.vectors.deinit();
    }
    
    /// Generate random level for new node using exponential decay
    fn generateRandomLevel(self: *HNSWIndex) u8 {
        const random = self.prng.random();
        var level: u8 = 0;
        
        while (random.float(f32) < self.config.ml and level < 16) { // Cap at 16 layers
            level += 1;
        }
        
        return level;
    }
    
    /// Calculate cosine similarity between two vectors
    fn calculateSimilarity(self: *const HNSWIndex, id1: u64, id2: u64) f32 {
        const vec1 = self.vectors.get(id1) orelse return 0.0;
        const vec2 = self.vectors.get(id2) orelse return 0.0;
        return vec1.cosineSimilarity(&vec2);
    }
    
    /// Search for ef closest elements to query in a specific layer
    fn searchLayer(self: *const HNSWIndex, query_id: u64, entry_points: []const u64, num_closest: u32, layer: u8) !std.ArrayList(SearchCandidate) {
        var visited = std.AutoHashMap(u64, void).init(self.allocator);
        defer visited.deinit();
        
        // Use two priority queues: candidates (min-heap) and w (max-heap)
        var candidates = std.PriorityQueue(SearchCandidate, void, SearchCandidate.lessThan).init(self.allocator, {});
        defer candidates.deinit();
        
        var w = std.PriorityQueue(SearchCandidate, void, struct {
            fn lessThan(_: void, a: SearchCandidate, b: SearchCandidate) std.math.Order {
                return std.math.order(b.distance, a.distance); // Reverse order for max-heap
            }
        }.lessThan).init(self.allocator, {});
        defer w.deinit();
        
        // Initialize with entry points
        for (entry_points) |ep_id| {
            const similarity = self.calculateSimilarity(query_id, ep_id);
            const candidate = SearchCandidate{ .id = ep_id, .distance = -similarity }; // Negative for max-heap
            
            try candidates.add(candidate);
            try w.add(candidate);
            try visited.put(ep_id, {});
        }
        
        // Search
        while (candidates.count() > 0) {
            const current = candidates.remove();
            
            // Stop if current is farther than furthest in w
            if (w.count() >= num_closest) {
                const furthest = w.peek() orelse break;
                if (current.distance > furthest.distance) break;
            }
            
            // Get connections for current node in specified layer
            if (layer < self.layers.items.len) {
                if (self.layers.items[layer].get(current.id)) |node| {
                    for (node.connections.items) |neighbor_id| {
                        if (visited.contains(neighbor_id)) continue;
                        try visited.put(neighbor_id, {});
                        
                        const similarity = self.calculateSimilarity(query_id, neighbor_id);
                        const neighbor_candidate = SearchCandidate{ 
                            .id = neighbor_id, 
                            .distance = -similarity 
                        };
                        
                        // Add to candidates if closer than furthest in w
                        if (w.count() < num_closest) {
                            try candidates.add(neighbor_candidate);
                            try w.add(neighbor_candidate);
                        } else {
                            const furthest = w.peek() orelse continue;
                            if (neighbor_candidate.distance < furthest.distance) {
                                try candidates.add(neighbor_candidate);
                                try w.add(neighbor_candidate);
                                _ = w.remove(); // Remove furthest
                            }
                        }
                    }
                }
            }
        }
        
        // Convert w to result list (sorted by similarity descending)
        var results = std.ArrayList(SearchCandidate).init(self.allocator);
        var temp_list = std.ArrayList(SearchCandidate).init(self.allocator);
        defer temp_list.deinit();
        
        while (w.count() > 0) {
            try temp_list.append(w.remove());
        }
        
        // Reverse to get descending order
        var i: usize = temp_list.items.len;
        while (i > 0) {
            i -= 1;
            try results.append(temp_list.items[i]);
        }
        
        return results;
    }
    
    /// Select M neighbors for a node using a simple heuristic
    fn selectNeighbors(self: *const HNSWIndex, candidates: []const SearchCandidate, max_connections: u32) !std.ArrayList(u64) {
        var selected = std.ArrayList(u64).init(self.allocator);
        
        // Simple heuristic: select the closest ones
        const actual_m = @min(max_connections, @as(u32, @intCast(candidates.len)));
        for (candidates[0..actual_m]) |candidate| {
            try selected.append(candidate.id);
        }
        
        return selected;
    }
    
    /// Insert a vector into the HNSW index
    pub fn insert(self: *HNSWIndex, vector: types.Vector) !void {
        // Store the vector
        try self.vectors.put(vector.id, vector);
        
        // Generate level for new node
        const level = self.generateRandomLevel();
        
        // Ensure we have enough layers
        while (self.layers.items.len <= level) {
            try self.layers.append(std.AutoHashMap(u64, HNSWNode).init(self.allocator));
        }
        
        // If this is the first node or it's at a higher level than current entry point
        if (self.entry_point == null or level >= self.layers.items.len - 1) {
            self.entry_point = vector.id;
        }
        
        var entry_points = std.ArrayList(u64).init(self.allocator);
        defer entry_points.deinit();
        
        if (self.entry_point) |ep| {
            try entry_points.append(ep);
        }
        
        // Search from top layer down to level+1
        var current_layer = @as(i32, @intCast(self.layers.items.len)) - 1;
        while (current_layer > level) {
            const search_results = try self.searchLayer(vector.id, entry_points.items, 1, @intCast(current_layer));
            defer search_results.deinit();
            
            entry_points.clearRetainingCapacity();
            if (search_results.items.len > 0) {
                try entry_points.append(search_results.items[0].id);
            }
            
            current_layer -= 1;
        }
        
        // Insert into layers from level down to 0
        var layer_idx = level;
        while (true) {
            const max_conn = if (layer_idx == 0) self.config.max_connections_layer0 else self.config.max_connections;
            
            // Search for candidates
            const candidates = try self.searchLayer(vector.id, entry_points.items, self.config.ef_construction, layer_idx);
            defer candidates.deinit();
            
            // Select neighbors
            const neighbors = try self.selectNeighbors(candidates.items, max_conn);
            defer neighbors.deinit();
            
            // Create node for this layer
            var node = HNSWNode.init(self.allocator, vector.id, layer_idx);
            errdefer node.deinit(); // Clean up on error
            
            for (neighbors.items) |neighbor_id| {
                try node.addConnection(neighbor_id);
            }
            
            // Add node to layer
            try self.layers.items[layer_idx].put(vector.id, node);
            
            // Add bidirectional connections
            for (neighbors.items) |neighbor_id| {
                if (self.layers.items[layer_idx].getPtr(neighbor_id)) |neighbor_node| {
                    try neighbor_node.addConnection(vector.id);
                    
                    // Prune connections if necessary
                    if (neighbor_node.connections.items.len > max_conn) {
                        // Simple pruning: remove random connections (could be improved)
                        const excess = neighbor_node.connections.items.len - max_conn;
                        for (0..excess) |_| {
                            const idx = self.prng.random().intRangeAtMost(usize, 0, neighbor_node.connections.items.len - 1);
                            _ = neighbor_node.connections.orderedRemove(idx);
                        }
                    }
                }
            }
            
            // Update entry points for next layer
            entry_points.clearRetainingCapacity();
            for (neighbors.items) |neighbor_id| {
                try entry_points.append(neighbor_id);
            }
            
            if (layer_idx == 0) break;
            layer_idx -= 1;
        }
    }
    
    /// Search for k nearest neighbors
    pub fn search(self: *const HNSWIndex, query_id: u64, k: u32, ef: u32) !std.ArrayList(types.SimilarityResult) {
        var result = std.ArrayList(types.SimilarityResult).init(self.allocator);
        
        // Check if query vector exists
        if (!self.vectors.contains(query_id)) {
            return result; // Return empty result
        }
        
        // Check if we have any vectors
        if (self.entry_point == null) {
            return result;
        }
        
        var entry_points = std.ArrayList(u64).init(self.allocator);
        defer entry_points.deinit();
        try entry_points.append(self.entry_point.?);
        
        // Search from top layer down to layer 1
        var current_layer = @as(i32, @intCast(self.layers.items.len)) - 1;
        while (current_layer > 0) {
            const search_results = try self.searchLayer(query_id, entry_points.items, 1, @intCast(current_layer));
            defer search_results.deinit();
            
            entry_points.clearRetainingCapacity();
            if (search_results.items.len > 0) {
                try entry_points.append(search_results.items[0].id);
            }
            
            current_layer -= 1;
        }
        
        // Search layer 0 with ef
        const candidates = try self.searchLayer(query_id, entry_points.items, @max(ef, k), 0);
        defer candidates.deinit();
        
        // Convert to SimilarityResult and limit to k
        const actual_k = @min(k, @as(u32, @intCast(candidates.items.len)));
        for (candidates.items[0..actual_k]) |candidate| {
            // Skip self-matches
            if (candidate.id == query_id) continue;
            
            try result.append(types.SimilarityResult{
                .id = candidate.id,
                .similarity = -candidate.distance, // Convert back to positive similarity
            });
        }
        
        return result;
    }
    
    /// Get HNSW statistics
    pub fn getStats(self: *const HNSWIndex) HNSWStats {
        var total_connections: u64 = 0;
        var layer_connections = std.ArrayList(u64).init(self.allocator);
        defer layer_connections.deinit();
        
        for (self.layers.items) |*layer| {
            var connections_in_layer: u64 = 0;
            var iter = layer.iterator();
            while (iter.next()) |entry| {
                connections_in_layer += entry.value_ptr.connections.items.len;
            }
            layer_connections.append(connections_in_layer) catch {};
            total_connections += connections_in_layer;
        }
        
        const avg_connections = if (self.layers.items.len > 0) 
            @as(f32, @floatFromInt(total_connections)) / @as(f32, @floatFromInt(self.layers.items.len))
        else 
            0.0;
        
        return HNSWStats{
            .num_vectors = self.vectors.count(),
            .num_layers = @intCast(self.layers.items.len),
            .entry_point = self.entry_point orelse 0,
            .total_connections = total_connections,
            .avg_connections_per_layer = avg_connections,
        };
    }
};

test "VectorIndex basic operations" {
    const allocator = std.testing.allocator;
    
    var index = VectorIndex.init(allocator);
    defer index.deinit();

    // Create test vectors
    const dims1 = [_]f32{ 1.0, 0.0, 0.0 } ++ [_]f32{0.0} ** 125;
    const dims2 = [_]f32{ 0.0, 1.0, 0.0 } ++ [_]f32{0.0} ** 125;
    
    const vec1 = types.Vector.init(1, &dims1);
    const vec2 = types.Vector.init(2, &dims2);

    // Add vectors
    try index.addVector(vec1);
    try index.addVector(vec2);

    // Test retrieval
    try std.testing.expect(index.getVector(1) != null);
    try std.testing.expect(index.getVectorCount() == 2);

    // Test removal
    try std.testing.expect(index.removeVector(1) == true);
    try std.testing.expect(index.getVectorCount() == 1);
    try std.testing.expect(index.getVector(1) == null);
}

test "VectorSearch similarity queries" {
    const allocator = std.testing.allocator;
    
    var index = VectorIndex.init(allocator);
    defer index.deinit();

    // Create test vectors
    const dims1 = [_]f32{ 1.0, 0.0, 0.0 } ++ [_]f32{0.0} ** 125;
    const dims2 = [_]f32{ 0.9, 0.1, 0.0 } ++ [_]f32{0.0} ** 125; // Similar to dims1
    const dims3 = [_]f32{ 0.0, 0.0, 1.0 } ++ [_]f32{0.0} ** 125; // Orthogonal to dims1
    
    try index.addVector(types.Vector.init(1, &dims1));
    try index.addVector(types.Vector.init(2, &dims2));
    try index.addVector(types.Vector.init(3, &dims3));

    const search = VectorSearch.init(allocator);
    
    // Test similarity search
    const similar = try search.querySimilar(&index, 1, 2);
    defer similar.deinit();
    
    try std.testing.expect(similar.items.len == 2);
    try std.testing.expect(similar.items[0].similarity > similar.items[1].similarity); // Should be sorted
    try std.testing.expect(similar.items[0].id == 2); // Vector 2 should be most similar to 1
}

test "VectorSearch threshold queries" {
    const allocator = std.testing.allocator;
    
    var index = VectorIndex.init(allocator);
    defer index.deinit();

    // Create test vectors
    const dims1 = [_]f32{ 1.0, 0.0, 0.0 } ++ [_]f32{0.0} ** 125;
    const dims2 = [_]f32{ 0.8, 0.6, 0.0 } ++ [_]f32{0.0} ** 125; // High similarity
    const dims3 = [_]f32{ 0.1, 0.0, 0.0 } ++ [_]f32{0.0} ** 125; // Low similarity
    
    try index.addVector(types.Vector.init(1, &dims1));
    try index.addVector(types.Vector.init(2, &dims2));
    try index.addVector(types.Vector.init(3, &dims3));

    const search = VectorSearch.init(allocator);
    
    // Test threshold search
    const threshold_results = try search.querySimilarityThreshold(&index, 1, 0.5);
    defer threshold_results.deinit();
    
    // Should only include vector 2 (high similarity)
    try std.testing.expect(threshold_results.items.len == 1);
    try std.testing.expect(threshold_results.items[0].id == 2);
}

test "VectorClustering k-means" {
    const allocator = std.testing.allocator;
    
    const clustering = VectorClustering.init(allocator);
    
    // Create test vectors in two groups
    var vectors = [_]types.Vector{
        types.Vector.init(1, &([_]f32{ 1.0, 0.0, 0.0 } ++ [_]f32{0.0} ** 125)),
        types.Vector.init(2, &([_]f32{ 0.9, 0.1, 0.0 } ++ [_]f32{0.0} ** 125)),
        types.Vector.init(3, &([_]f32{ 0.0, 0.0, 1.0 } ++ [_]f32{0.0} ** 125)),
        types.Vector.init(4, &([_]f32{ 0.0, 0.1, 0.9 } ++ [_]f32{0.0} ** 125)),
    };
    
    var clusters = try clustering.kMeansClustering(&vectors, 2, 10);
    defer {
        for (clusters.items) |*cluster| {
            cluster.deinit();
        }
        clusters.deinit();
    }
    
    try std.testing.expect(clusters.items.len == 2);
    
    // Each cluster should have members
    var total_members: u32 = 0;
    for (clusters.items) |cluster| {
        total_members += @intCast(cluster.members.items.len);
    }
    try std.testing.expect(total_members == 4);
} 