const std = @import("std");

/// HTTP Client Demo for ContextDB API
/// This demonstrates how to interact with the ContextDB HTTP API
/// Run the HTTP server first with: zig build http-server
pub fn main() !void {
    const demo_text = 
        \\ContextDB HTTP API Client Demo
        \\===============================
        \\
        \\Make sure to start the ContextDB HTTP server first:
        \\  zig build http-server
        \\
        \\Here are example curl commands to interact with the API:
        \\
        \\== Health Check ==
        \\curl -X GET http://localhost:8080/api/v1/health
        \\# Returns: {"status":"healthy","mode":"single-node",...}
        \\
        \\== Database Metrics ==
        \\curl -X GET http://localhost:8080/api/v1/metrics
        \\# Returns: {"metrics":{"nodes":6,"edges":6,...}}
        \\
        \\== Insert a Node ==
        \\curl -X POST http://localhost:8080/api/v1/nodes \
        \\  -H "Content-Type: application/json" \
        \\  -d '{"id": 100, "label": "NewUser"}'
        \\# Returns: {"id":100,"status":"created"}
        \\
        \\== Insert an Edge ==
        \\curl -X POST http://localhost:8080/api/v1/edges \
        \\  -H "Content-Type: application/json" \
        \\  -d '{"from": 1, "to": 100, "kind": "related"}'
        \\# Returns: {"from":1,"to":100,"status":"created"}
        \\
        \\== Insert a Vector ==
        \\curl -X POST http://localhost:8080/api/v1/vectors \
        \\  -H "Content-Type: application/json" \
        \\  -d '{"id": 100, "dims": [0.1, 0.9, 0.3, 0.2]}'
        \\# Returns: {"id":100,"status":"created"}
        \\
        \\== Query Related Nodes ==
        \\curl -X GET http://localhost:8080/api/v1/nodes/1/related
        \\# Returns: {"nodes":[{"id":2,"label":"Bob"},{"id":3,"label":"Document1"}]}
        \\
        \\== Query Similar Vectors ==
        \\curl -X GET http://localhost:8080/api/v1/vectors/1/similar
        \\# Returns: {"vectors":[{"id":3,"similarity":0.912871},{"id":2,"similarity":0.845154}]}
        \\
        \\== Batch Insert ==
        \\curl -X POST http://localhost:8080/api/v1/batch \
        \\  -H "Content-Type: application/json" \
        \\  -d '{
        \\    "nodes": [
        \\      {"id": 200, "label": "BatchNode1"},
        \\      {"id": 201, "label": "BatchNode2"}
        \\    ],
        \\    "edges": [
        \\      {"from": 200, "to": 201, "kind": "links"}
        \\    ],
        \\    "vectors": [
        \\      {"id": 200, "dims": [1.0, 0.0, 0.0]}
        \\    ]
        \\  }'
        \\# Returns: {"inserted":{"nodes":2,"edges":1,"vectors":1},"status":"created"}
        \\
        \\== Hybrid Query (Graph + Vector) ==
        \\curl -X POST http://localhost:8080/api/v1/query/hybrid \
        \\  -H "Content-Type: application/json" \
        \\  -d '{"node_id": 1, "depth": 2, "top_k": 5}'
        \\# Returns: {"related_nodes":[...],"similar_vectors":[...]}
        \\
        \\== Create Snapshot ==
        \\curl -X POST http://localhost:8080/api/v1/snapshot
        \\# Returns: {"snapshot_id":1,"timestamp":1642000000}
        \\
        \\== Available Edge Types ==
        \\Edge types you can use in the "kind" field:
        \\- "owns"       - Ownership relationship
        \\- "links"      - General link relationship
        \\- "related"    - Related entities
        \\- "child_of"   - Parent-child hierarchy
        \\- "similar_to" - Similarity relationship
        \\
        \\== Testing with JSON Files ==
        \\You can also save JSON data to files and use them:
        \\
        \\# Save this to node.json:
        \\{"id": 300, "label": "FileNode"}
        \\
        \\# Then use it:
        \\curl -X POST http://localhost:8080/api/v1/nodes \
        \\  -H "Content-Type: application/json" \
        \\  -d @node.json
        \\
        \\== Performance Testing ==
        \\For performance testing, you can use tools like Apache Bench:
        \\ab -n 1000 -c 10 -H "Content-Type: application/json" \
        \\   -p node.json http://localhost:8080/api/v1/nodes
        \\
        \\Or hey for more detailed metrics:
        \\hey -n 1000 -c 10 -H "Content-Type: application/json" \
        \\   -D node.json http://localhost:8080/api/v1/nodes
        \\
        \\== Next Steps ==
        \\1. Start the HTTP server: zig build http-server
        \\2. Try the curl commands above
        \\3. Check the health endpoint to see sample data
        \\4. Experiment with your own data!
        \\5. Build applications that integrate with ContextDB via HTTP
        \\
        \\Happy querying! 🚀
        \\
    ;

    std.debug.print("{s}", .{demo_text});
} 