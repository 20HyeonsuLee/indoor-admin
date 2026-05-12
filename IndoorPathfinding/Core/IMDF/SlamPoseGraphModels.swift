import Foundation
import CoreGraphics

/// RTABMap pose graph (rtabmap.db Node + Link) 표현.
struct SlamPoseGraph: Equatable {
    var nodes: [SlamPoseNode]
    var links: [SlamPoseLink]
}

struct SlamPoseNode: Identifiable, Equatable {
    let id: Int
    let stamp: Double
    let point: CGPoint   // 2D top-down (x, y)
    let z: Double
}

struct SlamPoseLink: Equatable {
    let fromId: Int
    let toId: Int
    let type: Int
}

extension SlamPoseLink {
    /// RTABMap Link.type
    /// 0: Neighbor, 1: GlobalClosure, 2: LocalSpaceClosure, 3: LocalTimeClosure,
    /// 4: UserClosure, 5: VirtualClosure, 6: NeighborMerged, 7: PosePrior, 8: Landmark, 9: 기타
    var category: SlamLinkCategory {
        switch type {
        case 0, 6: return .neighbor
        case 1, 2, 3, 4: return .loopClosure
        case 5: return .virtualClosure
        case 7, 8, 9: return .other
        default: return .other
        }
    }
}

enum SlamLinkCategory {
    case neighbor      // 시간 순서 인접 keyframe (trajectory backbone)
    case loopClosure   // 같은 장소 다시 방문 (graph optimization 핵심)
    case virtualClosure
    case other
}

enum SlamPoseGraphParserError: Error, LocalizedError {
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .invalidJSON: return "SLAM pose graph JSON 파싱 실패"
        }
    }
}

struct SlamPoseGraphParser {
    func parse(data: Data) throws -> SlamPoseGraph {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawNodes = object["nodes"] as? [[String: Any]],
              let rawLinks = object["links"] as? [[String: Any]] else {
            throw SlamPoseGraphParserError.invalidJSON
        }
        let nodes: [SlamPoseNode] = rawNodes.compactMap { dict in
            guard let id = dict["id"] as? Int,
                  let tx = dict["tx"] as? Double,
                  let ty = dict["ty"] as? Double else { return nil }
            let tz = dict["tz"] as? Double ?? 0
            let stamp = dict["stamp"] as? Double ?? 0
            return SlamPoseNode(
                id: id,
                stamp: stamp,
                point: CGPoint(x: tx, y: ty),
                z: tz
            )
        }
        let links: [SlamPoseLink] = rawLinks.compactMap { dict in
            guard let from = dict["from"] as? Int,
                  let to = dict["to"] as? Int,
                  let type = dict["type"] as? Int else { return nil }
            return SlamPoseLink(fromId: from, toId: to, type: type)
        }
        return SlamPoseGraph(nodes: nodes, links: links)
    }
}
