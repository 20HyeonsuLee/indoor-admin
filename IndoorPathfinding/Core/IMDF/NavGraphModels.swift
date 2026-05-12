import Foundation
import CoreGraphics

struct NavGraph: Equatable {
    var nodes: [NavGraphNode]
    var edges: [NavGraphEdge]

    var nodeById: [String: NavGraphNode] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    }
}

struct NavGraphNode: Identifiable, Equatable {
    let id: String
    let nodeType: String
    let label: String?
    let poiMarkId: Int?
    let point: CGPoint
    let z: Double
}

struct NavGraphEdge: Identifiable, Equatable {
    let id: String
    let fromNodeId: String
    let toNodeId: String
    let edgeType: String
    let lengthM: Double
    let polyline: [CGPoint]
}

enum NavGraphParserError: Error, LocalizedError {
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .invalidJSON: return "graph GeoJSON 파싱 실패"
        }
    }
}

struct NavGraphParser {
    func parse(data: Data) throws -> NavGraph {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = object["features"] as? [[String: Any]] else {
            throw NavGraphParserError.invalidJSON
        }
        var nodes: [NavGraphNode] = []
        var edges: [NavGraphEdge] = []
        for feature in features {
            guard let geometry = feature["geometry"] as? [String: Any],
                  let geomType = geometry["type"] as? String,
                  let props = feature["properties"] as? [String: Any] else { continue }
            switch geomType {
            case "Point":
                if let node = parseNode(geometry: geometry, props: props) {
                    nodes.append(node)
                }
            case "LineString":
                if let edge = parseEdge(geometry: geometry, props: props) {
                    edges.append(edge)
                }
            default: continue
            }
        }
        return NavGraph(nodes: nodes, edges: edges)
    }

    private func parseNode(geometry: [String: Any], props: [String: Any]) -> NavGraphNode? {
        guard let coords = geometry["coordinates"] as? [Double], coords.count >= 2,
              let id = props["node_id"] as? String,
              let type = props["node_type"] as? String else { return nil }
        let z = coords.count >= 3 ? coords[2] : 0
        return NavGraphNode(
            id: id,
            nodeType: type,
            label: props["label"] as? String,
            poiMarkId: props["poi_mark_id"] as? Int,
            point: CGPoint(x: coords[0], y: coords[1]),
            z: z
        )
    }

    private func parseEdge(geometry: [String: Any], props: [String: Any]) -> NavGraphEdge? {
        guard let raw = geometry["coordinates"] as? [[Double]],
              let id = props["edge_id"] as? String,
              let from = props["from_node_id"] as? String,
              let to = props["to_node_id"] as? String,
              let type = props["edge_type"] as? String else { return nil }
        let length = props["length_m"] as? Double ?? 0
        let polyline: [CGPoint] = raw.compactMap { coord in
            guard coord.count >= 2 else { return nil }
            return CGPoint(x: coord[0], y: coord[1])
        }
        guard polyline.count >= 2 else { return nil }
        return NavGraphEdge(
            id: id,
            fromNodeId: from,
            toNodeId: to,
            edgeType: type,
            lengthM: length,
            polyline: polyline
        )
    }
}
