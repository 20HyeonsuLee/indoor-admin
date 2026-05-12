import Foundation
import CoreGraphics

struct IMDFMap: Equatable {
    var manifest: IMDFManifest
    var footprint: [IMDFPolygonFeature]
    var units: [IMDFPolygonFeature]
    var amenities: [IMDFAmenityFeature]
    var anchors: [IMDFPointFeature]

    var bounds: IMDFBounds {
        var b = IMDFBounds.empty
        footprint.forEach { b.include($0.rings.flatMap { $0 }) }
        units.forEach { b.include($0.rings.flatMap { $0 }) }
        amenities.forEach { b.include($0.point) }
        anchors.forEach { b.include($0.point) }
        return b.isValid ? b : IMDFBounds(minX: -1, minY: -1, maxX: 1, maxY: 1)
    }
}

struct IMDFManifest: Equatable {
    var scanId: String
    var buildJobId: String
    var coordinateSystem: String
    var format: String
    var unitCount: Int?
    var rectified: Bool?
}

struct IMDFPolygonFeature: Identifiable, Equatable {
    var id: String
    var category: String
    var name: String?
    var semantic: Bool
    var sourcePoiMarkId: Int?
    var rings: [[CGPoint]]

    var center: CGPoint? {
        let points = rings.flatMap { $0 }
        guard !points.isEmpty else { return nil }
        let sx = points.reduce(CGFloat.zero) { $0 + $1.x }
        let sy = points.reduce(CGFloat.zero) { $0 + $1.y }
        return CGPoint(x: sx / CGFloat(points.count), y: sy / CGFloat(points.count))
    }
}

struct IMDFAmenityFeature: Identifiable, Equatable {
    var id: String
    var poiMarkId: Int?
    var name: String?
    var category: String
    var point: CGPoint
    var displayPoint: CGPoint?
    var displayAreaId: String?
    var connectorType: String?
    var connectorKey: String?
    var z: Double
}

struct IMDFPointFeature: Identifiable, Equatable {
    var id: String
    var point: CGPoint
    var z: Double
}

struct IMDFBounds: Equatable {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double

    static var empty: IMDFBounds {
        IMDFBounds(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity)
    }

    var isValid: Bool {
        minX.isFinite && minY.isFinite && maxX.isFinite && maxY.isFinite && minX < maxX && minY < maxY
    }

    mutating func include(_ point: CGPoint) {
        minX = min(minX, Double(point.x))
        minY = min(minY, Double(point.y))
        maxX = max(maxX, Double(point.x))
        maxY = max(maxY, Double(point.y))
    }

    mutating func include(_ points: [CGPoint]) {
        points.forEach { include($0) }
    }
}

struct RouteResponse: Decodable, Equatable {
    let scanId: String
    let scanIds: [String]?
    let buildJobId: String
    let buildJobIds: [String]?
    let pathGeometry: RouteGeometry
    let lengthM: Double
    let nodeCount: Int
    // M2: 서버 schema 필수 필드 추가 (path_nodes, snap_info, route_metadata)
    let pathNodes: [RouteNodePayload]
    let snapInfo: RouteSnapInfo
    let routeMetadata: [String: RouteMetadataValue]?

    enum CodingKeys: String, CodingKey {
        case scanId = "scan_id"
        case scanIds = "scan_ids"
        case buildJobId = "build_job_id"
        case buildJobIds = "build_job_ids"
        case pathGeometry = "path_geometry"
        case lengthM = "length_m"
        case nodeCount = "node_count"
        case pathNodes = "path_nodes"
        case snapInfo = "snap_info"
        case routeMetadata = "route_metadata"
    }
}

// M2: 서버 RouteNode 스키마 (snake_case CodingKeys)
struct RouteNodePayload: Decodable, Equatable {
    let nodeId: String?
    let x: Double?
    let y: Double?
    let z: Double?
    let nodeType: String?
    let label: String?
    let poiMarkId: Int?
    let scanId: String?
    let levelId: String?

    enum CodingKeys: String, CodingKey {
        case nodeId = "node_id"
        case x, y, z
        case nodeType = "node_type"
        case label
        case poiMarkId = "poi_mark_id"
        case scanId = "scan_id"
        case levelId = "level_id"
    }
}

// M2: snap_info 스키마 (snake_case CodingKeys)
struct RouteSnapInfo: Decodable, Equatable {
    let startSnapDistanceM: Double?
    let goalSnapDistanceM: Double?

    enum CodingKeys: String, CodingKey {
        case startSnapDistanceM = "start_snap_distance_m"
        case goalSnapDistanceM = "goal_snap_distance_m"
    }
}

// M2: route_metadata 값 타입 소거 (Bool/String/Double 허용)
enum RouteMetadataValue: Decodable, Equatable {
    case bool(Bool)
    case string(String)
    case double(Double)
    case int(Int)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        self = .bool(false)
    }
}

struct RouteGeometry: Decodable, Equatable {
    let type: String
    let coordinates: [[Double]]

    var points: [CGPoint] {
        coordinates.compactMap { coord in
            guard coord.count >= 2 else { return nil }
            return CGPoint(x: coord[0], y: coord[1])
        }
    }
}
