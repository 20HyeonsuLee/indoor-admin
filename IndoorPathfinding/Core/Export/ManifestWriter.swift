import Foundation

/// scan zip 에 포함되는 `manifest.json` 생성기.
///
/// Codex BLOCKER 3 (Sprint 49): byte-level deterministic manifest.
/// - exported_at, created_at 같은 wall-clock timestamp 사용 금지.
/// - JSON key 순서 고정 (sortedKeys).
///
/// Sprint 65 v6:
/// - metadata_version: 5 → 6
/// - mode: "raw_arkit_recording" — iOS RTAB-Map raw recording. 서버는 rtabmap-reprocess.
/// - rtabmap_reprocessed: false (iOS 시점). 서버 reprocess 후 true.
///
/// Sprint 67 v7:
/// - metadata_version: 6 → 7
/// - mode: "raw_video_recording" — 60fps HEVC video + poses.bin.
/// - RTAB-Map raw recording 은 계속 켜 둔다. 서버 main build 는 rtabmap.db 를 쓰고,
///   video/poses 는 dense evidence 와 quality report 의 부가 입력이다.
/// - 신규: video_path, poses_path, video_codec, video_fps_nominal,
///         pose_record_count, intrinsics_fx/fy/cx/cy.
/// - keyframes_included = false, keyframe_image_source = "video_frames".
/// - rtabmap_accepted_frame_count = 0 (raw recording 모드라 client visual accept count 없음).
struct ScanManifest: Codable {
    let metadataVersion: Int
    let scanId: String
    let mode: String
    let keyframesIncluded: Bool
    let keyframeImageSource: String
    let poiImageSource: String
    let rtabmapAcceptedFrameCount: Int
    let sidecarKeyframeMetaCount: Int
    let droppedRejectFrameImageCount: Int
    let rtabmapReprocessed: Bool
    let clientAppVersion: String

    // Sprint 67 — v7 video adapter 전용 (v6 에서는 nil 직렬화 안 함)
    let videoPath: String?
    let posesPath: String?
    let videoCodec: String?
    let videoFpsNominal: Int?
    let poseRecordCount: Int?
    let intrinsicsFx: Float?
    let intrinsicsFy: Float?
    let intrinsicsCx: Float?
    let intrinsicsCy: Float?

    enum CodingKeys: String, CodingKey {
        case metadataVersion = "metadata_version"
        case scanId = "scan_id"
        case mode
        case keyframesIncluded = "keyframes_included"
        case keyframeImageSource = "keyframe_image_source"
        case poiImageSource = "poi_image_source"
        case rtabmapAcceptedFrameCount = "rtabmap_accepted_frame_count"
        case sidecarKeyframeMetaCount = "sidecar_keyframe_meta_count"
        case droppedRejectFrameImageCount = "dropped_reject_frame_image_count"
        case rtabmapReprocessed = "rtabmap_reprocessed"
        case clientAppVersion = "client_app_version"
        case videoPath = "video_path"
        case posesPath = "poses_path"
        case videoCodec = "video_codec"
        case videoFpsNominal = "video_fps_nominal"
        case poseRecordCount = "pose_record_count"
        case intrinsicsFx = "intrinsics_fx"
        case intrinsicsFy = "intrinsics_fy"
        case intrinsicsCx = "intrinsics_cx"
        case intrinsicsCy = "intrinsics_cy"
    }
}

enum ManifestWriter {

    /// scan_id 디렉터리 root 에 `manifest.json` 을 생성한다.
    /// 동일 입력 → byte-level 동일 출력 보장 (sortedKeys + 고정 형식).
    static func write(
        scanDirectory: URL,
        manifest: ScanManifest
    ) throws -> URL {
        let url = scanDirectory.appendingPathComponent("manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Sprint 67 v7 — raw_video_recording mode manifest.
    /// - Parameters:
    ///   - scanId: scan UUID.
    ///   - sidecarKeyframeMetaCount: scan_metadata.db keyframe_meta row count (5Hz subset).
    ///   - poseRecordCount: poses.bin 의 record 수 (60Hz 전체).
    ///   - intrinsics: 세션 동안 고정. ARFrame.camera.intrinsics 의 fx/fy/cx/cy.
    ///   - clientAppVersion: Bundle short version.
    static func makeV7(
        scanId: String,
        sidecarKeyframeMetaCount: Int,
        poseRecordCount: Int,
        intrinsicsFx: Float,
        intrinsicsFy: Float,
        intrinsicsCx: Float,
        intrinsicsCy: Float,
        clientAppVersion: String
    ) -> ScanManifest {
        ScanManifest(
            metadataVersion: 9,    // 7 → 9 (Sprint 89 cycle 1: branch_edge schema)
            scanId: scanId,
            mode: "raw_video_recording",
            keyframesIncluded: false,
            keyframeImageSource: "video_frames",
            poiImageSource: "poi_photo_image_blob",
            rtabmapAcceptedFrameCount: 0,
            sidecarKeyframeMetaCount: sidecarKeyframeMetaCount,
            droppedRejectFrameImageCount: 0,
            rtabmapReprocessed: false,
            clientAppVersion: clientAppVersion,
            videoPath: VideoRecorder.videoFileName,
            posesPath: PoseFileWriter.posesFileName,
            videoCodec: "hevc",
            videoFpsNominal: 60,
            poseRecordCount: poseRecordCount,
            intrinsicsFx: intrinsicsFx,
            intrinsicsFy: intrinsicsFy,
            intrinsicsCx: intrinsicsCx,
            intrinsicsCy: intrinsicsCy
        )
    }

    /// Sprint 90 — live_rtabmap mode manifest.
    /// iOS에서 RTAB-Map을 라이브로 돌려 rtabmap.db를 직접 생성. mp4/poses.bin 없음.
    /// 서버는 이 db를 입력으로 reprocess (원본 raw recording 으로 사용).
    static func makeLiveRtabmap(
        scanId: String,
        sidecarKeyframeMetaCount: Int,
        intrinsicsFx: Float,
        intrinsicsFy: Float,
        intrinsicsCx: Float,
        intrinsicsCy: Float,
        clientAppVersion: String
    ) -> ScanManifest {
        ScanManifest(
            metadataVersion: 9,
            scanId: scanId,
            mode: "live_rtabmap",
            keyframesIncluded: false,
            keyframeImageSource: "rtabmap_db",
            poiImageSource: "poi_photo_image_blob",
            rtabmapAcceptedFrameCount: 0,    // iOS는 전량 push, 서버 reprocess가 accept count 결정
            sidecarKeyframeMetaCount: sidecarKeyframeMetaCount,
            droppedRejectFrameImageCount: 0,
            rtabmapReprocessed: false,        // 서버에서 reprocess 후 true로 갱신
            clientAppVersion: clientAppVersion,
            videoPath: nil,
            posesPath: nil,
            videoCodec: nil,
            videoFpsNominal: nil,
            poseRecordCount: nil,
            intrinsicsFx: intrinsicsFx,
            intrinsicsFy: intrinsicsFy,
            intrinsicsCx: intrinsicsCx,
            intrinsicsCy: intrinsicsCy
        )
    }

    /// Legacy Sprint 65 v6 — raw_arkit_recording mode (deprecate, 호환용).
    static func make(
        scanId: String,
        rtabmapAcceptedFrameCount: Int,
        sidecarKeyframeMetaCount: Int,
        clientAppVersion: String
    ) -> ScanManifest {
        let dropped = max(0, sidecarKeyframeMetaCount - rtabmapAcceptedFrameCount)
        return ScanManifest(
            metadataVersion: 6,
            scanId: scanId,
            mode: "raw_arkit_recording",
            keyframesIncluded: false,
            keyframeImageSource: "rtabmap_db_data_table",
            poiImageSource: "poi_photo_image_blob",
            rtabmapAcceptedFrameCount: rtabmapAcceptedFrameCount,
            sidecarKeyframeMetaCount: sidecarKeyframeMetaCount,
            droppedRejectFrameImageCount: dropped,
            rtabmapReprocessed: false,
            clientAppVersion: clientAppVersion,
            videoPath: nil,
            posesPath: nil,
            videoCodec: nil,
            videoFpsNominal: nil,
            poseRecordCount: nil,
            intrinsicsFx: nil,
            intrinsicsFy: nil,
            intrinsicsCx: nil,
            intrinsicsCy: nil
        )
    }
}
