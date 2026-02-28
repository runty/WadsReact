import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = DualPlayerViewModel()
    @State private var importerPresented = false
    @State private var activeImportKind: DualPlayerViewModel.VideoKind = .primary
    @State private var reactionURLSheetPresented = false
    @State private var reactionURLInput = ""
    @State private var isTheaterMode = false
    @State private var syncStepSeconds = 0.5
    @State private var isScrubbing = false
    @State private var scrubValue = 0.0
    @State private var pipOrigin = CGPoint(x: 24, y: 24)
    @State private var pipSize = CGSize(width: 360, height: 202)
    @State private var pipDragStartOrigin: CGPoint?
    @State private var pipDragStartPointer: CGPoint?
    @State private var pipResizeStartSize: CGSize?
    @State private var pipResizeStartPointer: CGPoint?
    @State private var hasInitializedPiP = false
    @State private var pipControlsVisible = true
    @State private var pipControlsAutoHideTicket = 0
    @State private var isDraggingPiP = false
    @State private var isResizingPiP = false
    @State private var mainVideoVerticalOffset = 0.0
    @State private var offsetInput = "+0.00"
    @FocusState private var isEditingOffsetField: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let pipHorizontalPadding = 16.0
    private let pipTopPadding = 16.0
    private let pipBottomPadding = 0.0
    private let pipMinSize = CGSize(width: 180, height: 101)
    private let pipDefaultSize = CGSize(width: 360, height: 202)
    private let mainVideoNudgePoints = 20.0
    private let controlCardCornerRadius = 14.0

    private var controlPanelSpacing: CGFloat {
        horizontalSizeClass == .compact ? 10 : 8
    }

    private var isManipulatingPiP: Bool {
        isDraggingPiP || isResizingPiP
    }

    private var headerTopInset: CGFloat {
#if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? 8 : 0
#else
        0
#endif
    }

    private var importTypes: [UTType] {
        var types: [UTType] = [.movie]
        if let mkv = UTType(filenameExtension: "mkv") {
            types.append(mkv)
        }
        return types
    }

    private var scrubberRange: ClosedRange<Double> {
        0...max(model.durationSeconds, 1)
    }

    private var displayedTime: Double {
        isScrubbing ? scrubValue : model.currentSeconds
    }

    private var syncStatusText: String {
        if abs(model.reactionOffsetSeconds) < 0.01 {
            return "Reaction is aligned with the show."
        }

        if model.reactionOffsetSeconds > 0 {
            return String(format: "Reaction is delayed by %.2f seconds.", model.reactionOffsetSeconds)
        }

        return String(format: "Reaction is advanced by %.2f seconds.", abs(model.reactionOffsetSeconds))
    }

    private func secondsLabel(_ value: Double) -> String {
        let magnitude = value < 1 ? String(format: "%.2f", value) : String(format: "%.0f", value)
        let unit = value == 1 ? "second" : "seconds"
        return "\(magnitude) \(unit)"
    }

    private func formattedOffset(_ value: Double) -> String {
        String(format: "%+.2f", value)
    }

    private func commitOffsetInput() {
        let normalized = offsetInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")

        guard let parsed = Double(normalized) else {
            offsetInput = formattedOffset(model.reactionOffsetSeconds)
            return
        }

        model.setReactionOffset(to: parsed)
        offsetInput = formattedOffset(model.reactionOffsetSeconds)
    }

    private func presentImporter(for kind: DualPlayerViewModel.VideoKind) {
        activeImportKind = kind
        importerPresented = true
    }

    var body: some View {
        ZStack {
            if isTheaterMode {
                Color.black
                    .ignoresSafeArea()
            }

            VStack(spacing: isTheaterMode ? 0 : 16) {
                if !isTheaterMode {
                    header
                }

                if isTheaterMode {
                    players
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    players
                }

                if !isTheaterMode {
                    controlsPanel
                }
            }
            .padding(isTheaterMode ? 0 : 16)
            .padding(.top, isTheaterMode ? 0 : headerTopInset)
        }
        .overlay(alignment: .bottomTrailing) {
            if !isTheaterMode {
                floatingTheaterButton
                    .padding(.trailing, 16)
                    .padding(.bottom, 14)
            }
        }
        .onAppear {
            offsetInput = formattedOffset(model.reactionOffsetSeconds)
        }
        .onChange(of: model.reactionOffsetSeconds) { _, newValue in
            if !isEditingOffsetField {
                offsetInput = formattedOffset(newValue)
            }
        }
        .onChange(of: isEditingOffsetField) { _, isFocused in
            if !isFocused {
                commitOffsetInput()
            }
        }
        .alert(
            "Unable to Open Video",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        model.alertMessage = nil
                    }
                }
            ),
            actions: {
                Button("OK", role: .cancel) {}
            },
            message: {
                Text(model.alertMessage ?? "")
            }
        )
        .fileImporter(
            isPresented: $importerPresented,
            allowedContentTypes: importTypes,
            allowsMultipleSelection: false
        ) { result in
            model.importSelection(result, kind: activeImportKind)
        }
        .sheet(isPresented: $reactionURLSheetPresented) {
            reactionURLSheet
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    presentImporter(for: .primary)
                } label: {
                    Label("Choose Show/Movie", systemImage: "film")
                }

                Button {
                    presentImporter(for: .reaction)
                } label: {
                    Label("Choose Reaction", systemImage: "person.2")
                }

                Button {
                    reactionURLInput = ""
                    reactionURLSheetPresented = true
                } label: {
                    Label("Choose Reaction from URL", systemImage: "link.badge.plus")
                }
            }

            if let message = model.importActivityMessage {
                HStack(spacing: 8) {
                    if let progress = model.importActivityProgress {
                        ProgressView(value: progress)
                            .frame(width: 140)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reactionURLSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose Reaction from URL")
                .font(.title3.weight(.semibold))

            Text("Paste a YouTube, Vimeo, or direct media URL (`.mp4` / `.m3u8`).")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("https://", text: $reactionURLInput)
                .textFieldStyle(.roundedBorder)
#if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
#endif

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    reactionURLSheetPresented = false
                }

                Button("Load") {
                    model.importFromURLString(reactionURLInput, kind: .reaction)
                    reactionURLSheetPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(reactionURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 420)
    }

    private var floatingTheaterButton: some View {
        Button {
            isTheaterMode.toggle()
            if isTheaterMode {
                hasInitializedPiP = false
            }
        } label: {
            Label("Theatre Mode", systemImage: "rectangle.inset.filled.and.person.filled")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(.blue)
        .controlSize(.large)
    }

    private var players: some View {
        Group {
            if isTheaterMode {
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        theaterMainPlayer(in: geometry.size)
                        theaterMainPositionControls(in: geometry.size)
                        theaterExitButton

                        if model.hasReactionVideo {
                            theaterReactionPiP(in: geometry.size)
                        }
                    }
                    .onAppear {
                        initializePiP(in: geometry.size)
                    }
                    .onChange(of: geometry.size) { _, newSize in
                        initializePiP(in: newSize)
                        clampPiPToBounds(in: newSize)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            } else {
                splitPlayers
            }
        }
    }

    private var splitPlayers: some View {
        Group {
            if horizontalSizeClass == .compact {
                VStack(spacing: 12) {
                    videoPane(
                        title: "Show / Movie",
                        fileName: model.primaryTitle,
                        player: model.primaryPlayer,
                        loaded: model.hasPrimaryVideo,
                        onEmptyTap: { presentImporter(for: .primary) }
                    )

                    reactionPane
                }
            } else {
                HStack(spacing: 12) {
                    videoPane(
                        title: "Show / Movie",
                        fileName: model.primaryTitle,
                        player: model.primaryPlayer,
                        loaded: model.hasPrimaryVideo,
                        onEmptyTap: { presentImporter(for: .primary) }
                    )

                    reactionPane
                }
            }
        }
    }

    private func theaterMainHeight(in container: CGSize) -> CGFloat {
        let ratio = max(model.primaryVideoAspectRatio, 0.1)
        let fitHeight = container.width / ratio
        return min(container.height, fitHeight)
    }

    private func theaterMainPlayer(in container: CGSize) -> some View {
        ZStack {
            VideoPlayer(player: model.primaryPlayer)

            if !model.hasPrimaryVideo {
                Rectangle()
                    .fill(.black.opacity(0.55))
                Text("No show/movie selected")
                    .foregroundStyle(.white)
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        presentImporter(for: .primary)
                    }
            }
        }
        .frame(width: container.width, height: theaterMainHeight(in: container), alignment: .top)
        .offset(y: mainVideoVerticalOffset)
    }

    private func theaterMainPositionControls(in _: CGSize) -> some View {
        VStack(spacing: 4) {
            theaterMainNudgeButton(systemImage: "chevron.up") {
                mainVideoVerticalOffset -= mainVideoNudgePoints
            }

            theaterMainNudgeButton(systemImage: "chevron.down") {
                mainVideoVerticalOffset += mainVideoNudgePoints
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, 12)
        .padding(.bottom, 14)
    }

    private var theaterExitButton: some View {
        Button {
            isTheaterMode = false
        } label: {
            Label("Exit Theatre Mode", systemImage: "xmark.circle.fill")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.title2)
        .foregroundStyle(.white.opacity(0.9))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 12)
        .padding(.bottom, 14)
    }

    private func theaterMainNudgeButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
                .foregroundStyle(.white)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.35), lineWidth: 0.8)
                }
        }
        .buttonStyle(.plain)
    }

    private func theaterReactionPiP(in container: CGSize) -> some View {
        reactionPiPSurface
            .frame(width: pipSize.width, height: pipSize.height)
            .background(.black)
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 26, height: 26)
                .overlay(
                    Image(systemName: "hand.draw.fill")
                        .font(.caption2)
                )
                .padding(8)
                .opacity(pipControlsVisible ? 1 : 0)
            }
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 26, height: 26)
                .overlay(
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2)
                )
                .padding(8)
                .contentShape(Rectangle())
                .gesture(pipResizeGesture(in: container))
                .opacity(pipControlsVisible ? 1 : 0)
            }
            .contentShape(Rectangle())
            .gesture(pipDragGesture(in: container))
            .simultaneousGesture(TapGesture().onEnded {
                revealPiPControls()
            })
            .onAppear {
                revealPiPControls()
            }
            .task(id: pipControlsAutoHideTicket) {
                guard isTheaterMode else { return }

                try? await Task.sleep(for: .seconds(2.0))
                guard !Task.isCancelled else { return }
                guard !isManipulatingPiP else { return }

                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.25)) {
                        pipControlsVisible = false
                    }
                }
            }
            .position(
                x: pipOrigin.x + (pipSize.width / 2),
                y: pipOrigin.y + (pipSize.height / 2)
            )
    }

    private var reactionPane: some View {
        Group {
            if model.isReactionYouTube, let videoID = model.reactionYouTubeVideoID {
                youtubeVideoPane(
                    title: "Reaction",
                    fileName: model.reactionTitle,
                    videoID: videoID,
                    loaded: model.hasReactionVideo
                )
            } else {
                videoPane(
                    title: "Reaction",
                    fileName: model.reactionTitle,
                    player: model.reactionPlayer,
                    loaded: model.hasReactionVideo
                )
            }
        }
    }

    private var reactionPiPSurface: some View {
        Group {
            if model.isReactionYouTube, let videoID = model.reactionYouTubeVideoID {
                YouTubePlayerSurfaceView(
                    bridge: model.reactionYouTubeBridge,
                    videoID: videoID,
                    showsNativeControls: false
                )
            } else {
                PlayerSurfaceView(player: model.reactionPlayer)
            }
        }
    }

    private func videoPane(
        title: String,
        fileName: String,
        player: AVPlayer,
        loaded: Bool,
        onEmptyTap: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .fixedSize(horizontal: true, vertical: false)

                Text(fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ZStack {
                VideoPlayer(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                if !loaded {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.black.opacity(0.55))
                    Text("No video selected")
                        .foregroundStyle(.white)

                    if let onEmptyTap {
                        Rectangle()
                            .fill(.clear)
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                            .onTapGesture {
                                onEmptyTap()
                            }
                    }
                }
            }
            .frame(minHeight: 220)
        }
        .frame(maxWidth: .infinity)
    }

    private func youtubeVideoPane(title: String, fileName: String, videoID: String, loaded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .fixedSize(horizontal: true, vertical: false)

                Text(fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ZStack {
                YouTubePlayerSurfaceView(
                    bridge: model.reactionYouTubeBridge,
                    videoID: videoID,
                    showsNativeControls: true
                )
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                if !loaded {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.black.opacity(0.55))
                    Text("No video selected")
                        .foregroundStyle(.white)
                }
            }
            .frame(minHeight: 220)
        }
        .frame(maxWidth: .infinity)
    }

    private func initializePiP(in container: CGSize) {
        guard isTheaterMode, !hasInitializedPiP else {
            return
        }

        let size = clampedPiPSize(pipDefaultSize, in: container)
        pipSize = size
        pipOrigin = CGPoint(
            x: container.width - size.width - pipHorizontalPadding,
            y: container.height - size.height - pipBottomPadding
        )
        hasInitializedPiP = true
        revealPiPControls()
    }

    private func clampPiPToBounds(in container: CGSize) {
        let size = clampedPiPSize(pipSize, in: container)
        pipSize = size
        pipOrigin = clampedPiPOrigin(pipOrigin, size: size, in: container)
    }

    private func clampedPiPSize(_ proposed: CGSize, in container: CGSize) -> CGSize {
        let maxWidth = max(pipMinSize.width, container.width - (pipHorizontalPadding * 2))
        let maxHeight = max(pipMinSize.height, container.height - pipTopPadding - pipBottomPadding)
        return CGSize(
            width: min(max(proposed.width, pipMinSize.width), maxWidth),
            height: min(max(proposed.height, pipMinSize.height), maxHeight)
        )
    }

    private func clampedPiPOrigin(_ proposed: CGPoint, size: CGSize, in container: CGSize) -> CGPoint {
#if os(iOS)
        // Allow partial off-screen placement on iOS while keeping enough visible area to grab.
        let minVisibleWidth = min(72.0, size.width)
        let minVisibleHeight = min(72.0, size.height)
        let minX = minVisibleWidth - size.width
        let maxX = container.width - minVisibleWidth
        let minY = minVisibleHeight - size.height
        let maxY = container.height - minVisibleHeight
#else
        let minX = pipHorizontalPadding
        let maxX = max(pipHorizontalPadding, container.width - size.width - pipHorizontalPadding)
        let minY = pipTopPadding
        let maxY = max(pipTopPadding, container.height - size.height - pipBottomPadding)
#endif
        return CGPoint(
            x: min(max(proposed.x, minX), maxX),
            y: min(max(proposed.y, minY), maxY)
        )
    }

    private func pipDragGesture(in container: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard !isResizingPiP else {
                    return
                }

                if pipDragStartOrigin == nil {
                    pipDragStartOrigin = pipOrigin
                    pipDragStartPointer = value.startLocation
                    isDraggingPiP = true
                    revealPiPControls()
                }

                let start = pipDragStartOrigin ?? pipOrigin
                let startPointer = pipDragStartPointer ?? value.startLocation
                let deltaX = value.location.x - startPointer.x
                let deltaY = value.location.y - startPointer.y
                let proposed = CGPoint(
                    x: start.x + deltaX,
                    y: start.y + deltaY
                )

                pipOrigin = clampedPiPOrigin(proposed, size: pipSize, in: container)
            }
            .onEnded { _ in
                pipDragStartOrigin = nil
                pipDragStartPointer = nil
                isDraggingPiP = false
                revealPiPControls()
            }
    }

    private func pipResizeGesture(in container: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if pipResizeStartSize == nil {
                    pipResizeStartSize = pipSize
                    pipResizeStartPointer = value.startLocation
                    isResizingPiP = true
                    revealPiPControls()
                }

                let start = pipResizeStartSize ?? pipSize
                let startPointer = pipResizeStartPointer ?? value.startLocation
                let deltaX = value.location.x - startPointer.x
                let deltaY = value.location.y - startPointer.y
                let proposed = CGSize(
                    width: start.width + deltaX,
                    height: start.height + deltaY
                )

                let clamped = clampedPiPSize(proposed, in: container)
                pipSize = clamped
                pipOrigin = clampedPiPOrigin(pipOrigin, size: clamped, in: container)
            }
            .onEnded { _ in
                pipResizeStartSize = nil
                pipResizeStartPointer = nil
                isResizingPiP = false
                revealPiPControls()
            }
    }

    private func revealPiPControls() {
        withAnimation(.easeOut(duration: 0.2)) {
            pipControlsVisible = true
        }
        pipControlsAutoHideTicket += 1
    }

    private var controlsPanel: some View {
        VStack(spacing: controlPanelSpacing) {
            compactControlCard {
                transport
            }

            if horizontalSizeClass == .compact {
                controlCard {
                    settings
                }

                controlCard {
                    subtitleControls
                }

                controlCard {
                    volumeControls
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 12) {
                        controlCard {
                            settings
                        }

                        controlCard {
                            subtitleControls
                        }
                    }
                    .frame(maxWidth: .infinity)

                    controlCard {
                        volumeControls
                    }
                    .frame(maxWidth: 420)
                }
            }
        }
    }

    private func controlCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: controlCardCornerRadius, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: controlCardCornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            )
    }

    private func compactControlCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            )
    }

    private func sectionHeader(_ title: String, systemImage: String, color: Color) -> some View {
        Label {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(color)
        }
    }

    private var transport: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { displayedTime },
                    set: { value in
                        scrubValue = value
                    }
                ),
                in: scrubberRange,
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if editing {
                        scrubValue = model.currentSeconds
                    } else {
                        model.seek(to: scrubValue)
                    }
                }
            )

            HStack(spacing: 10) {
                Text(model.formatTime(displayedTime))
                    .monospacedDigit()
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 54, alignment: .leading)

                Spacer(minLength: 4)

                Button {
                    model.skip(by: -10)
                } label: {
                    Image(systemName: "gobackward.10")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    model.playPause()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    model.skip(by: 10)
                } label: {
                    Image(systemName: "goforward.10")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer(minLength: 4)

                Text(model.formatTime(model.durationSeconds))
                    .monospacedDigit()
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 54, alignment: .trailing)
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Reaction Offset", systemImage: "link", color: .orange)

            HStack(spacing: 10) {
                Text("Offset")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                TextField("0.00", text: $offsetInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 92)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .focused($isEditingOffsetField)
#if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
#endif
                    .onSubmit {
                        commitOffsetInput()
                    }

                Text("seconds")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(formattedOffset(model.reactionOffsetSeconds))s")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        model.nudgeReactionOffset(by: -syncStepSeconds)
                    } label: {
                        Label("Earlier", systemImage: "chevron.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Menu {
                        ForEach([0.05, 0.1, 0.5, 1.0, 5.0, 15.0], id: \.self) { step in
                            Button {
                                syncStepSeconds = step
                            } label: {
                                if abs(syncStepSeconds - step) < 0.001 {
                                    Label(secondsLabel(step), systemImage: "checkmark")
                                } else {
                                    Text(secondsLabel(step))
                                }
                            }
                        }
                    } label: {
                        Label("Step \(secondsLabel(syncStepSeconds))", systemImage: "dial.medium")
                            .frame(minWidth: 138)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        model.nudgeReactionOffset(by: syncStepSeconds)
                    } label: {
                        Label("Later", systemImage: "chevron.forward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }

                HStack(spacing: 8) {
                    Button {
                        model.matchOffsetToCurrentFrames()
                    } label: {
                        Label("Match Frames", systemImage: "scope")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.canMatchCurrentFrames)

                    Button {
                        model.resetReactionOffset()
                    } label: {
                        Label("Reset Offset", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }

            Text(syncStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var volumeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Audio Levels", systemImage: "speaker.wave.2.fill", color: .green)

            HStack(spacing: 10) {
                Label("Show", systemImage: "film")
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .frame(width: 118, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { model.primaryVolume },
                        set: { value in
                            model.setPrimaryVolume(to: value)
                        }
                    ),
                    in: 0...model.maxVolume
                )

                Button {
                    model.togglePrimaryMute()
                } label: {
                    Image(systemName: model.primaryVolume <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 10) {
                Label("Reaction", systemImage: "person.2")
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .frame(width: 118, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { model.reactionVolume },
                        set: { value in
                            model.setReactionVolume(to: value)
                        }
                    ),
                    in: 0...model.maxVolume
                )

                Button {
                    model.toggleReactionMute()
                } label: {
                    Image(systemName: model.reactionVolume <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitleControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Subtitles (Main Video)", systemImage: "captions.bubble.fill", color: .mint)

            Picker(
                "Subtitle Track",
                selection: Binding(
                    get: { model.selectedSubtitleID },
                    set: { id in
                        model.selectSubtitle(id: id)
                    }
                )
            ) {
                ForEach(model.subtitleChoices) { choice in
                    Text(choice.title).tag(choice.id)
                }
            }
            .pickerStyle(.menu)
            .disabled(!model.hasPrimaryVideo)

            if model.hasPrimaryVideo, model.subtitleChoices.count <= 1 {
                Text("No subtitle tracks detected in this file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
