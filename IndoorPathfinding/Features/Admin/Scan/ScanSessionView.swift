import SwiftUI
import ARKit

/// ARKit 스캔 세션 화면.
/// - ScanStore를 @State로 소유하며, onAppear에 start(), onDisappear에 stop().
/// - 백그라운드 진입 시 scenePhase 감지 → stop() 호출로 ARSession 즉시 중단.
/// - 종료 후 zip 생성 → onFinished(zipURL) 콜백 → AdminFloorDetailView가 업로드 처리.
///
/// Sprint 88 Cycle 3: UI 재배치 — topZone/bottomZone 분리.
struct ScanSessionView: View {
    @Environment(\.dismiss) private var dismiss
    let launchContext: ScanLaunchContext
    let onFinished: (URL) async -> Void
    let onDiscarded: () -> Void
    @State private var store: ScanStore
    @State private var startError: String?
    @State private var hudVisible: Bool = true
    @State private var connectorPrefix: String
    @State private var connectorType: ScanStore.InterfloorConnectorType = .elevator
    @State private var toolMode: ScanToolMode = .corridor
    // F6: AppStorage 영속화
    @AppStorage("scan.lastCorridorWidthM") private var selectedWidthM: Double = 2.5
    @State private var showWidthCustomSheet: Bool = false
    @State private var customWidthInput: String = ""
    @State private var showFinalizeChecklist: Bool = false
    @State private var showNodeEdit: Bool = false
    @State private var showProximityCandidates: Bool = false
    @State private var telemetryNow: Date = .now
    @Environment(\.scenePhase) private var scenePhase

    init(
        launchContext: ScanLaunchContext,
        serverClient: IndoorServerV1Client? = nil,
        onFinished: @escaping (URL) async -> Void,
        onDiscarded: @escaping () -> Void
    ) {
        self.launchContext = launchContext
        self.onFinished = onFinished
        self.onDiscarded = onDiscarded
        _store = State(initialValue: ScanStore(
            context: launchContext,
            serverClient: serverClient
        ))
        _connectorPrefix = State(initialValue: "EV-A")
    }

    var body: some View {
        ZStack {
            arBackground

            // AR Node Overlay
            GeometryReader { geo in
                ARNodeOverlayView(
                    markingState: store.markingState,
                    arFrame: store.rawCornerTapDebugMode ? store.latestARFrame : nil,
                    viewportSize: geo.size,
                    onNodeTap: { nodeId in store.beginEdit(nodeId: nodeId) },
                    onCornerTap: toolMode == .corner ? { screenPoint in
                        handleCornerTap(at: screenPoint)
                    } : nil,
                    onPlacementTap: placementTapHandler,
                    debugRawCornerTaps: store.rawCornerTapDebugMode ? store.debugRawCornerTaps : [],
                    debugRaycastWorldPoints: store.rawCornerTapDebugMode ? store.debugRaycastWorldPoints : [],
                    debugRaycastAnchorIds: store.rawCornerTapDebugMode ? store.debugRaycastAnchorIds : []
                )
            }
            .ignoresSafeArea()

            // top/bottom zone 레이아웃 (AR 가시영역 = Spacer)
            overlayContent

            // F8: tracking limited 화면 중앙 large overlay (AC-UI-4)
            if store.trackingStateLabel != "normal" && store.phase == .recording {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.yellow)
                    Text("트래킹 회복 중 — 잠시 정지")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .padding(20)
                .background(.black.opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            if store.phase == .finalizing {
                VStack(spacing: 8) {
                    ProgressView()
                        .tint(.white)
                    Text("스캔 저장 중")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .padding(18)
                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
            }

            // Micro Toast (top-center)
            VStack {
                if let msg = store.microToastMessage {
                    MicroToastView(message: msg) {
                        store.undo(count: 1)
                    }
                    .padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .animation(.easeInOut(duration: 0.2), value: store.microToastMessage)
        }
        .navigationBarHidden(true)
        .navigationBarBackButtonHidden(true)
        .statusBarHidden(true)
        .onAppear(perform: beginSession)
        .onDisappear {
            if store.phase == .recording { store.stop() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background, store.phase == .recording {
                store.stop()
            }
        }
        .onChange(of: store.phase) { _, newPhase in
            handlePhaseChange(newPhase)
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now in
            telemetryNow = now
        }
        .onChange(of: store.pendingCorridorPlacement?.id) { _, placementId in
            if placementId != nil {
                showProximityCandidates = true
            }
        }
        .alert("오류", isPresented: Binding(
            get: { startError != nil },
            set: { if !$0 { startError = nil } }
        )) {
            Button("확인") {
                onDiscarded()
                dismiss()
            }
        } message: {
            Text(startError ?? "")
        }
        .alert("작업 실패", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.clearLastError() } }
        )) {
            Button("확인") { store.clearLastError() }
        } message: {
            Text(store.lastError ?? "")
        }
        // FinalizeChecklistSheet
        .sheet(isPresented: $showFinalizeChecklist) {
            FinalizeChecklistSheet(
                result: store.finalizeChecklistResult,
                onFix: { showFinalizeChecklist = false },
                onIgnore: {
                    showFinalizeChecklist = false
                    store.stop()
                }
            )
        }
        // NodeEditSheet
        .sheet(
            isPresented: Binding(
                get: { store.editingNodeId != nil },
                set: { if !$0 { store.endEdit() } }
            )
        ) {
            if let nodeId = store.editingNodeId,
               let node = store.markingState.nodes.first(where: { $0.id == nodeId }) {
                NodeEditSheet(
                    node: node,
                    edgeCount: store.markingState.edgeCount(for: nodeId),
                    onSave: { nodeType, widthM in
                        store.commitEdit(nodeId: nodeId, nodeType: nodeType, widthM: widthM)
                    },
                    onDelete: {
                        store.deleteBranchNode(nodeId)
                        store.endEdit()
                    },
                    onDismiss: { store.endEdit() }
                )
            }
        }
        // Width custom input sheet
        .sheet(isPresented: $showWidthCustomSheet) {
            widthCustomInputSheet
        }
        // Proximity candidate sheet (Medium-B)
        .sheet(isPresented: $showProximityCandidates) {
            proximityCandidateSheet
        }
        // F6: onAppear에서 AppStorage 값으로 store 동기화
        .onAppear {
            store.setCorridorWidth(selectedWidthM)
        }
    }

    // MARK: - Subviews

    @ViewBuilder private var arBackground: some View {
        if let session = store.arSession {
            ARPreviewView(session: session) { view in
                // Sprint 88 cycle_4 H10: ARSCNView ref → viewport-aware raycastQuery
                // Sprint 88 cycle_5: store.setSceneView(_:) 가 sceneViewRef + MarkARSceneOverlay delegate 동시 연결
                store.setSceneView(view)
            }
            .ignoresSafeArea()
        } else {
            Color.black.ignoresSafeArea()
        }
    }

    /// Sprint 88 Cycle 3: topZone / bottomZone 분리 레이아웃.
    /// AR 카메라 가시영역 = Spacer() 중간 (손가락 cluster 침범 없음).
    private var overlayContent: some View {
        VStack(spacing: 0) {
            topZone
                .padding(.horizontal, 16)
                .padding(.top, 8)
            Spacer()
            bottomZone
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
    }

    // MARK: - Top Zone (정보 + 정지 버튼)

    private var topZone: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 첫 줄: 트래킹 + coverage compact + 업로드 badge + 정지 버튼
            HStack(spacing: 8) {
                trackingBanner
                Spacer()
                coverageCompactStrip
                // streaming 전송 badge — 항상 노출.
                streamingBadge
                stopButton
            }
            // 두 번째 줄: context ribbon slim
            contextRibbonSlim
            // HUD compact (toggle)
            if hudVisible {
                hudCompactStrip
                streamingTelemetryStrip
            }
            // hint banner (조건부)
            if let hint = store.hintBannerCase ?? store.markingState.hintBannerCase {
                HintBannerView(hint: hint) {
                    store.clearHintBanner()
                }
            }
            // POI 수집 배너
            poiCollectionBanner
        }
    }

    // MARK: - Bottom Zone (도구 + 액션)

    private var bottomZone: some View {
        VStack(spacing: 8) {
            // Row 1: 도구 모드 selector
            toolModeSegmented
            // Row 2: width selector (corridor only)
            if toolMode == .corridor {
                WidthSelectorView(
                    selectedWidthM: $selectedWidthM,
                    onCustomTap: { showWidthCustomSheet = true }
                )
                .onChange(of: selectedWidthM) { _, newValue in
                    store.setCorridorWidth(newValue)
                }
                // Row 3: connect mode indicator (F1)
                connectModeIndicator
            }
            // Row 4: action cluster (mode-dependent)
            actionClusterByMode
        }
    }

    // MARK: - Top Zone Subviews

    /// compact 트래킹 상태 dot + label (eye toggle 포함)
    private var trackingBanner: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(trackingColor)
                .frame(width: 8, height: 8)
            Text(trackingLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white)
            Button {
                hudVisible.toggle()
            } label: {
                Image(systemName: hudVisible ? "eye.fill" : "eye.slash.fill")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            // Debug: raw corner tap mode 토글
            if toolMode == .corner {
                Button {
                    store.rawCornerTapDebugMode.toggle()
                    if !store.rawCornerTapDebugMode {
                        store.clearDebugRawCornerTaps()
                    }
                } label: {
                    Text(store.rawCornerTapDebugMode ? "raw●" : "raw○")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(store.rawCornerTapDebugMode ? .pink : .white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.4))
        .clipShape(Capsule())
    }

    /// Coverage compact 1줄: "1F 88%" 형태
    private var coverageCompactStrip: some View {
        Text("\(store.context.floorName) \(coveragePercent)%")
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(coveragePercent >= 85 ? Color.green : Color.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.4))
            .clipShape(Capsule())
    }

    /// 정지 버튼 — top-trailing 단독 (AC-UI-6). 44×44 pt target 보장.
    private var stopButton: some View {
        Button {
            let checklist = store.finalizeChecklistResult
            if checklist.hasIssues {
                showFinalizeChecklist = true
            } else {
                store.stop()
            }
        } label: {
            Image(systemName: "stop.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.red)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.4))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(store.phase != .recording)
    }

    /// Context ribbon slim: "공학1관 1F · 보통(2.5m)"
    private var contextRibbonSlim: some View {
        let widthLabel = store.markingState.lastCorridorWidthM == 2.5 ? "보통" :
                         store.markingState.lastCorridorWidthM == 1.5 ? "좁음" :
                         store.markingState.lastCorridorWidthM == 4.0 ? "넓음" :
                         "\(String(format: "%.1f", store.markingState.lastCorridorWidthM))m"
        return Text("\(store.context.uploadSummary) · \(widthLabel)(\(String(format: "%.1f", store.markingState.lastCorridorWidthM))m)")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.8))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// HUD compact 1줄: "196/210f · 11n · 4iv · 1q"
    private var hudCompactStrip: some View {
        Text("\(store.keyframeCount)/\(store.capturedFrameCount)f · \(store.branchMarkCount)n · \(store.interfloorMarkCount)iv · \(store.pendingQueueCount)q")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.black.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// streaming 전송 badge: "전송 N/M nodes"
    private var streamingBadge: some View {
        let confirmed = store.streamingLastConfirmedNodeId
        let total = store.statsModel.stats.nodeCount
        let hasError = store.pushErrorMessage != nil
        return Label(
            "전송 \(confirmed)/\(total)",
            systemImage: store.isStreamingActive ? "arrow.up.circle.fill" : "arrow.up.circle"
        )
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            hasError ? Color.red.opacity(0.8) : Color.blue.opacity(0.8),
            in: Capsule()
        )
    }

    /// streaming telemetry 1줄
    private var streamingTelemetryStrip: some View {
        let confirmed = store.streamingLastConfirmedNodeId
        let total = store.statsModel.stats.nodeCount
        let stateLabel = store.isStreamingActive ? "push 중" : (store.isFinalizeComplete ? "완료" : "대기")
        return Text("streaming \(stateLabel) · 전송 \(confirmed)/\(total) nodes")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(store.pushErrorMessage != nil ? Color.red : Color.white.opacity(0.75))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Bottom Zone Subviews

    /// 도구 모드 segmented (하단으로 이동 — AC-UI-3)
    private var toolModeSegmented: some View {
        HStack(spacing: 4) {
            ForEach(ScanToolMode.nodeSegmentedCases) { mode in
                Button {
                    if toolMode != mode {
                        store.setTool(mode)
                        toolMode = mode
                    }
                } label: {
                    Text(mode.title)
                        .font(.caption2.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 36)
                        .foregroundStyle(toolMode == mode ? .black : .white)
                        .background(
                            toolMode == mode ? .white : .white.opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// F1 연결 모드 인디케이터: sequential 🟢 / proximityArmed 🟠
    private var connectModeIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(store.markingState.connectMode == .sequential ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(store.markingState.connectMode == .sequential ? "직선 연결" : "근처 노드 자동 연결")
                .font(.caption2)
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    /// 액션 cluster — toolMode에 따라 다른 버튼 표시
    @ViewBuilder private var actionClusterByMode: some View {
        switch store.markMode {
        case .idle:
            idleActionCluster
        case .manualPositionSelected:
            poiPhotoConfirmButtons
        case .confirming:
            ProgressView().tint(.white).padding(.vertical, 12)
        }
    }

    /// idle 상태 액션 cluster (toolMode별)
    @ViewBuilder private var idleActionCluster: some View {
        switch toolMode {
        case .scan:
            Label("스캔 범위를 채우면서 이동", systemImage: "figure.walk.motion")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .padding(.vertical, 12)
                .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))

        case .poi:
            Label("화면에서 POI 위치를 탭하세요", systemImage: "hand.tap")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .padding(.vertical, 12)
                .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))

        case .corridor:
            corridorActionCluster

        case .corner:
            cornerActionCluster

        case .connector:
            connectorControls
        }
    }

    /// Corridor 3-button cluster: [끊기] [⊕마크] [↶취소] (AC-UI-2 ≥44×44)
    private var corridorActionCluster: some View {
        HStack(spacing: 8) {
            // 끊기 버튼
            Button {
                store.enableProximityOnce()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "scissors")
                        .font(.title3)
                    Text("끊기")
                        .font(.caption2.bold())
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(store.markingState.connectMode == .proximityArmed ? .yellow : .white)
            .disabled(store.phase != .recording)

            VStack(spacing: 4) {
                Image(systemName: "hand.tap.fill")
                    .font(.title3)
                Text(store.markingState.connectMode == .proximityArmed ? "위치 탭 후 연결" : "화면 탭")
                    .font(.caption2.bold())
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .padding(.vertical, 10)
            .background(.orange, in: RoundedRectangle(cornerRadius: 8))

            // 취소(undo)
            Button {
                store.undo(count: 1)
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.title3)
                    Text("취소")
                        .font(.caption2.bold())
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .disabled(store.markingState.undoStack.isEmpty)
        }
    }

    /// Corner 모드: 안내 + 취소 (F4: square.dashed 아이콘)
    private var cornerActionCluster: some View {
        HStack(spacing: 8) {
            Label("원하는 코너 위치를 탭하세요", systemImage: "square.dashed")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .padding(.vertical, 12)
                .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))

            Button {
                store.undo(count: 1)
            } label: {
                Label("취소", systemImage: "arrow.uturn.backward")
                    .font(.caption.bold())
                    .frame(minWidth: 60)
                    .frame(minHeight: 44)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .disabled(store.markingState.undoStack.isEmpty)
        }
    }

    /// POI 수집 상태 배너 (manual 모드).
    @ViewBuilder private var poiCollectionBanner: some View {
        switch store.markMode {
        case .idle:
            EmptyView()
        case .manualPositionSelected:
            bannerText("POI 위치 선택됨. 사진 찍기 버튼으로 등록.", color: .teal)
        case .confirming:
            bannerText("마킹 저장 중...", color: .gray)
        }
    }

    private func bannerText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(color.opacity(0.8))
            .foregroundStyle(.white)
            .clipShape(Capsule())
            .padding(.top, 8)
    }

    private var connectorControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker("층간 연결", selection: $connectorType) {
                    ForEach(ScanStore.InterfloorConnectorType.allCases) { type in
                        Label(type.title, systemImage: type.icon).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: connectorType) { _, newValue in
                    connectorPrefix = "\(newValue.prefixSeed)-A"
                }

                TextField("Prefix", text: $connectorPrefix)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.caption.monospaced())
                    .frame(width: 72)
                    .textFieldStyle(.roundedBorder)
            }

            Label("연결 위치를 화면에서 탭하세요", systemImage: "hand.tap")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.purple.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.bottom, 12)
    }

    /// POI 위치 선택 후 "사진 찍고 등록 | 취소" 2열.
    private var poiPhotoConfirmButtons: some View {
        HStack(spacing: 16) {
            Button {
                store.confirmManualPOI(label: nil)
            } label: {
                Label("사진 찍고 등록", systemImage: "camera.fill")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)

            Button {
                store.cancelPOI()
            } label: {
                Label("취소", systemImage: "xmark")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .tint(.white)
        }
        .padding(.bottom, 12)
    }

    // (Track Lock POI 흐름은 ADR 0002로 폐기 — trackingEmptyButtons/trackingWithPhotosButtons 제거)

    // MARK: - Proximity Candidate Sheet (Medium-B)

    private var proximityCandidateSheet: some View {
        NavigationView {
            let candidates = store.proximityCandidates(radiusM: 3.0)
            List {
                if candidates.isEmpty {
                    Section {
                        Text("근처 visible 노드 없음")
                            .foregroundStyle(.red)
                        Button("고립 등록 (연결 없이)") {
                            store.commitPendingCorridor(widthM: selectedWidthM, connectNodeId: nil)
                            showProximityCandidates = false
                        }
                        Button("취소") {
                            store.clearPendingCorridorPlacement()
                            store.clearProximityMode()
                            showProximityCandidates = false
                        }
                    }
                } else {
                    Section("근처 노드 선택 (3m 이내)") {
                        ForEach(candidates) { node in
                            Button {
                                store.commitPendingCorridor(widthM: selectedWidthM, connectNodeId: node.id)
                                showProximityCandidates = false
                            } label: {
                                HStack {
                                    Image(systemName: "circle.fill")
                                        .foregroundStyle(.white)
                                    VStack(alignment: .leading) {
                                        Text("노드 #\(node.order)")
                                            .font(.subheadline.weight(.semibold))
                                        if let w = node.widthM {
                                            Text("폭 \(String(format: "%.1f", w))m")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("연결할 노드 선택")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") {
                        store.clearPendingCorridorPlacement()
                        store.clearProximityMode()
                        showProximityCandidates = false
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var placementTapHandler: ((CGPoint) -> Void)? {
        switch toolMode {
        case .corridor:
            return { point in
                store.markCorridorAtScreenPoint(point, widthM: selectedWidthM)
            }
        case .poi:
            return { point in
                store.selectPOIPlacementAtScreenPoint(point)
            }
        case .connector:
            return { point in
                store.markInterfloorConnectorAtScreenPoint(
                    point,
                    type: connectorType,
                    prefix: connectorPrefix
                )
            }
        case .scan, .corner:
            return nil
        }
    }

    private var trackingColor: Color {
        switch store.trackingStateLabel {
        case "normal": return .green
        case "limited.initializing", "limited.relocalizing": return .yellow
        default: return .red
        }
    }

    private var trackingLabel: String {
        switch store.trackingStateLabel {
        case "normal": return "트래킹 정상"
        case "limited.initializing": return "초기화 중..."
        case "limited.excessiveMotion": return "너무 빠름"
        case "limited.insufficientFeatures": return "특징점 부족"
        case "limited.relocalizing": return "재측위 중"
        case "notAvailable": return "ARKit 없음"
        default: return store.trackingStateLabel
        }
    }

    private var coveragePercent: Int {
        min(100, Int((Double(store.coveragePoints.count) / 120.0) * 100.0))
    }

    // MARK: - Corner Tap Handler

    private func handleCornerTap(at screenPoint: CGPoint) {
        store.markCornerAtScreenPoint(screenPoint)
    }

    // MARK: - Width Custom Input Sheet

    private var widthCustomInputSheet: some View {
        NavigationView {
            Form {
                Section("직접 입력 (1.0 ~ 15.0m)") {
                    TextField("폭 (m)", text: $customWidthInput)
                        .keyboardType(.decimalPad)
                }
            }
            .navigationTitle("복도 폭 입력")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { showWidthCustomSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("확인") {
                        if let value = Double(customWidthInput),
                           value >= 1.0, value <= 15.0 {
                            selectedWidthM = (value * 10).rounded() / 10
                        }
                        showWidthCustomSheet = false
                    }
                }
            }
        }
    }

    // MARK: - Session Lifecycle

    private func beginSession() {
        do {
            try store.start()
        } catch {
            startError = error.localizedDescription
        }
    }

    private func handlePhaseChange(_ phase: ScanStore.Phase) {
        switch phase {
        case .paused:
            handlePausedPhase()
        case .failed(let msg):
            startError = msg
        default:
            break
        }
    }

    private func handlePausedPhase() {
        // streaming 모델: finalize → streaming drain은 ScanStore.finalize() 내에서 비동기 처리.
        // paused 전환 후 즉시 finalize + dismiss.
        Task {
            do {
                try store.finalize()
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run {
                    startError = "스캔 마감 실패: \(error.localizedDescription)"
                }
            }
        }
    }
}

/// Sprint 88 Cycle 2: 도구 모드 enum 확장.
/// - scan / poi: 기존 (스캔/목적지)
/// - corridor: 이전 .branch 의미 — corridor node 등록
/// - corner: 코너 ARRaycast 탭 등록
/// - connector: 층간 연결 (기존)
enum ScanToolMode: String, CaseIterable, Identifiable {
    case scan
    case poi
    case corridor
    case corner
    case connector

    var id: String { rawValue }

    /// Sprint 88 cycle_7: 4-way segmented (POI 추가). .scan은 deprecate (enum 보존, segmented 미노출).
    static let nodeSegmentedCases: [ScanToolMode] = [.corridor, .corner, .poi, .connector]

    var title: String {
        switch self {
        case .scan:       return "스캔"
        case .poi:        return "목적지"
        case .corridor:   return "통로"
        case .corner:     return "코너"
        case .connector:  return "층간"
        }
    }

    var systemImage: String {
        switch self {
        case .scan:       return "figure.walk.motion"
        case .poi:        return "mappin.and.ellipse"
        case .corridor:   return "arrow.left.and.right"
        case .corner:     return "arrow.turn.right.up"
        case .connector:  return "arrow.up.arrow.down.square"
        }
    }
}

#Preview {
    ScanSessionView(
        launchContext: ScanLaunchContext(
            buildingId: UUID(),
            floorId: UUID(),
            floorName: "1F",
            floorLevel: 1,
            areaId: nil,
            areaLabel: "default"
        ),
        onFinished: { _ in },
        onDiscarded: {}
    )
}
