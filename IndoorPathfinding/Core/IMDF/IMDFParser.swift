import Foundation
import CoreGraphics

enum IMDFParserError: Error, Equatable {
    case missingManifest
    case invalidJSON(String)
}

struct IMDFParser {
    func parse(files: [String: Data]) throws -> IMDFMap {
        guard let manifestData = files["manifest.json"] else {
            throw IMDFParserError.missingManifest
        }
        let manifestObject = try jsonObject(manifestData, name: "manifest.json")
        let manifest = parseManifest(manifestObject)

        return IMDFMap(
            manifest: manifest,
            footprint: parsePolygonFeatures(try featureCollection(files["footprint.geojson"], name: "footprint.geojson")),
            units: parsePolygonFeatures(try featureCollection(files["unit.geojson"], name: "unit.geojson")),
            amenities: parseAmenityFeatures(try featureCollection(files["amenity.geojson"], name: "amenity.geojson")),
            anchors: parsePointFeatures(try featureCollection(files["anchor.geojson"], name: "anchor.geojson"))
        )
    }

    private func jsonObject(_ data: Data, name: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IMDFParserError.invalidJSON(name)
        }
        return object
    }

    private func featureCollection(_ data: Data?, name: String) throws -> [[String: Any]] {
        guard let data else { return [] }
        let object = try jsonObject(data, name: name)
        return object["features"] as? [[String: Any]] ?? []
    }

    private func parseManifest(_ object: [String: Any]) -> IMDFManifest {
        let unitSplit = object["unit_split"] as? [String: Any]
        let rectification = object["rectification"] as? [String: Any]
        return IMDFManifest(
            scanId: object["scan_id"] as? String ?? "",
            buildJobId: object["build_job_id"] as? String ?? "",
            coordinateSystem: object["coordinate_system"] as? String ?? "local_metric",
            format: object["format"] as? String ?? "",
            unitCount: unitSplit?["unit_count"] as? Int,
            rectified: rectification?["accepted"] as? Bool
        )
    }

    private func parsePolygonFeatures(_ features: [[String: Any]]) -> [IMDFPolygonFeature] {
        features.compactMap { feature in
            guard let geometry = feature["geometry"] as? [String: Any],
                  let rings = polygonRings(geometry)
            else { return nil }
            let properties = feature["properties"] as? [String: Any] ?? [:]
            return IMDFPolygonFeature(
                id: feature["id"] as? String ?? UUID().uuidString,
                category: properties["category"] as? String ?? "unknown",
                name: localizedName(properties["name"]),
                semantic: properties["semantic"] as? Bool ?? false,
                sourcePoiMarkId: properties["source_poi_mark_id"] as? Int,
                rings: rings
            )
        }
    }

    private func parseAmenityFeatures(_ features: [[String: Any]]) -> [IMDFAmenityFeature] {
        features.compactMap { feature in
            guard let geometry = feature["geometry"] as? [String: Any],
                  let point = point(geometry)
            else { return nil }
            let properties = feature["properties"] as? [String: Any] ?? [:]
            return IMDFAmenityFeature(
                id: feature["id"] as? String ?? UUID().uuidString,
                poiMarkId: properties["poi_mark_id"] as? Int,
                name: localizedName(properties["name"]),
                category: properties["category"] as? String ?? "unknown",
                point: point.xy,
                displayPoint: displayPoint(properties["display_point"]),
                displayAreaId: properties["display_area_id"] as? String,
                connectorType: properties["connector_type"] as? String,
                connectorKey: properties["connector_key"] as? String,
                z: point.z
            )
        }
    }

    private func parsePointFeatures(_ features: [[String: Any]]) -> [IMDFPointFeature] {
        features.compactMap { feature in
            guard let geometry = feature["geometry"] as? [String: Any],
                  let point = point(geometry)
            else { return nil }
            return IMDFPointFeature(
                id: feature["id"] as? String ?? UUID().uuidString,
                point: point.xy,
                z: point.z
            )
        }
    }

    private func polygonRings(_ geometry: [String: Any]) -> [[CGPoint]]? {
        let type = geometry["type"] as? String
        if type == "Polygon", let coordinates = geometry["coordinates"] as? [[[Double]]] {
            return coordinates.map { ring in ring.map { CGPoint(x: $0[0], y: $0[1]) } }
        }
        if type == "MultiPolygon", let coordinates = geometry["coordinates"] as? [[[[Double]]]] {
            return coordinates.flatMap { polygon in
                polygon.map { ring in ring.map { CGPoint(x: $0[0], y: $0[1]) } }
            }
        }
        return nil
    }

    private func point(_ geometry: [String: Any]) -> (xy: CGPoint, z: Double)? {
        guard geometry["type"] as? String == "Point",
              let coordinates = geometry["coordinates"] as? [Double],
              coordinates.count >= 2
        else { return nil }
        return (CGPoint(x: coordinates[0], y: coordinates[1]), coordinates.count >= 3 ? coordinates[2] : 0)
    }

    private func localizedName(_ raw: Any?) -> String? {
        if let text = raw as? String { return text }
        if let dict = raw as? [String: Any] {
            return dict["ko"] as? String ?? dict["en"] as? String
        }
        return nil
    }

    private func displayPoint(_ raw: Any?) -> CGPoint? {
        guard let coordinates = raw as? [Double], coordinates.count >= 2 else {
            return nil
        }
        return CGPoint(x: coordinates[0], y: coordinates[1])
    }
}
