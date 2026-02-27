import AVFoundation
import Combine
import SwiftUI

@MainActor
final class DualPlayerViewModel: ObservableObject {
    enum VideoKind {
        case primary
        case reaction
    }

    struct SubtitleChoice: Identifiable, Hashable {
        static let noneID = "subtitle-none"
        static let none = SubtitleChoice(id: noneID, title: "None")

        let id: String
        let title: String
    }

    let primaryPlayer = AVPlayer()
    let reactionPlayer = AVPlayer()

    @Published var primaryTitle = "No show/movie selected"
    @Published var reactionTitle = "No reaction selected"
    @Published var hasPrimaryVideo = false
    @Published var hasReactionVideo = false
    @Published var currentSeconds = 0.0
    @Published var durationSeconds = 1.0
    @Published var isPlaying = false
    @Published var reactionOffsetSeconds = 0.0
    @Published var primaryVideoAspectRatio = 16.0 / 9.0
    @Published var primaryVolume = 1.0
    @Published var reactionVolume = 1.0
    @Published private(set) var subtitleChoices: [SubtitleChoice] = [.none]
    @Published var selectedSubtitleID = SubtitleChoice.noneID
    @Published var alertMessage: String?

    let minReactionOffsetSeconds = -600.0
    let maxReactionOffsetSeconds = 600.0

    var canMatchCurrentFrames: Bool {
        hasPrimaryVideo && hasReactionVideo
    }

    private var primaryPeriodicTimeObserver: Any?
    private var reactionPeriodicTimeObserver: Any?
    private var endObservers: [NSObjectProtocol] = []
    private var securityScopedURLs: [URL] = []
    private var currentLegibleGroup: AVMediaSelectionGroup?
    private var legibleOptionByID: [String: AVMediaSelectionOption] = [:]

    private let observerInterval = CMTime(seconds: 0.1, preferredTimescale: 600)
    private let seekTimescale: CMTimeScale = 600
    private let startLeadTimeSeconds = 0.15
    private let hardResyncThresholdSeconds = 0.45
    private let rateCorrectionThresholdSeconds = 0.03
    private let maxRateAdjustment = 0.06
    private let rateCorrectionGain = 0.35
    private let correctionSeekTolerance = CMTime(seconds: 0.02, preferredTimescale: 600)

    init() {
        configurePlayersForSync()
        applyVolumeSettings()
        installObservers()
    }

    deinit {
        if let primaryPeriodicTimeObserver {
            primaryPlayer.removeTimeObserver(primaryPeriodicTimeObserver)
        }

        if let reactionPeriodicTimeObserver {
            reactionPlayer.removeTimeObserver(reactionPeriodicTimeObserver)
        }

        for observer in endObservers {
            NotificationCenter.default.removeObserver(observer)
        }

        for url in securityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
    }

    func importSelection(_ result: Result<[URL], Error>, kind: VideoKind) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else {
                return
            }
            Task { [weak self] in
                await self?.loadVideo(at: url, kind: kind)
            }
        case let .failure(error):
            alertMessage = error.localizedDescription
        }
    }

    func playPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard hasPrimaryVideo || hasReactionVideo else {
            return
        }

        if hasPrimaryVideo, hasReactionVideo {
            startSynchronizedPlayback()
        } else if hasPrimaryVideo {
            primaryPlayer.playImmediately(atRate: 1.0)
        } else if hasReactionVideo {
            reactionPlayer.playImmediately(atRate: 1.0)
        }

        isPlaying = true
    }

    func pause() {
        primaryPlayer.pause()
        reactionPlayer.pause()
        isPlaying = false
    }

    func skip(by deltaSeconds: Double) {
        seek(to: currentSeconds + deltaSeconds)
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, max(durationSeconds, 0)))
        currentSeconds = clamped

        if hasPrimaryVideo, hasReactionVideo {
            if isPlaying {
                startSynchronizedPlayback(primarySeconds: clamped)
            } else {
                let primaryTarget = CMTime(seconds: clamped, preferredTimescale: seekTimescale)
                primaryPlayer.seek(to: primaryTarget, toleranceBefore: .zero, toleranceAfter: .zero)

                let reactionTarget = reactionTime(forPrimarySeconds: clamped)
                reactionPlayer.seek(to: reactionTarget, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            return
        }

        if hasPrimaryVideo {
            let primaryTarget = CMTime(seconds: clamped, preferredTimescale: seekTimescale)
            primaryPlayer.seek(to: primaryTarget, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        if hasReactionVideo {
            let reactionTarget = reactionTime(forPrimarySeconds: clamped)
            reactionPlayer.seek(to: reactionTarget, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        if isPlaying {
            if hasPrimaryVideo {
                primaryPlayer.playImmediately(atRate: 1.0)
            } else if hasReactionVideo {
                reactionPlayer.playImmediately(atRate: 1.0)
            }
        }
    }

    func realignReactionToPrimary() {
        guard hasReactionVideo else {
            return
        }

        let primarySeconds = hasPrimaryVideo ? primaryPlayer.currentTime().seconds : 0
        let reactionTarget = reactionTime(forPrimarySeconds: primarySeconds)

        if hasPrimaryVideo, isPrimaryActuallyPlaying, isReactionActuallyPlaying {
            startSynchronizedPlayback(primarySeconds: primarySeconds)
        } else {
            reactionPlayer.seek(to: reactionTarget, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func setReactionOffset(to seconds: Double) {
        reactionOffsetSeconds = clampReactionOffset(seconds)
        realignReactionToPrimary()
    }

    func nudgeReactionOffset(by deltaSeconds: Double) {
        setReactionOffset(to: reactionOffsetSeconds + deltaSeconds)
    }

    func resetReactionOffset() {
        setReactionOffset(to: 0)
    }

    func setPrimaryVolume(to value: Double) {
        primaryVolume = clampVolume(value)
        applyVolumeSettings()
    }

    func setReactionVolume(to value: Double) {
        reactionVolume = clampVolume(value)
        applyVolumeSettings()
    }

    func selectSubtitle(id: String) {
        selectedSubtitleID = id
        applySubtitleSelection()
    }

    func togglePrimaryMute() {
        if primaryVolume <= 0.001 {
            setPrimaryVolume(to: 1.0)
        } else {
            setPrimaryVolume(to: 0)
        }
    }

    func toggleReactionMute() {
        if reactionVolume <= 0.001 {
            setReactionVolume(to: 1.0)
        } else {
            setReactionVolume(to: 0)
        }
    }

    func matchOffsetToCurrentFrames() {
        guard hasPrimaryVideo, hasReactionVideo else {
            return
        }

        let primarySeconds = primaryPlayer.currentTime().seconds
        let reactionSeconds = reactionPlayer.currentTime().seconds

        guard primarySeconds.isFinite, reactionSeconds.isFinite else {
            return
        }

        // Positive offset means reaction plays later than the show.
        setReactionOffset(to: primarySeconds - reactionSeconds)
    }

    func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else {
            return "00:00"
        }

        let clamped = max(0, Int(seconds.rounded()))
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let secs = clamped % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    private func loadVideo(at url: URL, kind: VideoKind) async {
        retainSecurityScope(for: url)

        let asset = AVURLAsset(url: url)
        let playable: Bool

        do {
            playable = try await asset.load(.isPlayable)
        } catch {
            alertMessage = "Could not read the selected file: \(error.localizedDescription)"
            return
        }

        guard playable else {
            if url.pathExtension.lowercased() == "mkv" {
                alertMessage = "This MKV file is not playable by AVPlayer on this device. Try MP4/MOV (H.264/H.265 + AAC)."
            } else {
                alertMessage = "This file format or codec is not playable by AVPlayer."
            }
            return
        }

        let item = AVPlayerItem(asset: asset)

        switch kind {
        case .primary:
            await refreshPrimaryVideoAspectRatio(for: asset)
            primaryPlayer.replaceCurrentItem(with: item)
            primaryTitle = url.lastPathComponent
            hasPrimaryVideo = true
            await refreshPrimarySubtitleChoices(for: item)
        case .reaction:
            reactionPlayer.replaceCurrentItem(with: item)
            reactionTitle = url.lastPathComponent
            hasReactionVideo = true
        }

        updateTimeline()
        if isPlaying {
            play()
        } else {
            realignReactionToPrimary()
        }
    }

    private func refreshPrimaryVideoAspectRatio(for asset: AVAsset) async {
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else {
                primaryVideoAspectRatio = 16.0 / 9.0
                return
            }

            let naturalSize = try await track.load(.naturalSize)
            let preferredTransform = try await track.load(.preferredTransform)
            let transformedSize = naturalSize.applying(preferredTransform)

            let width = abs(transformedSize.width)
            let height = abs(transformedSize.height)

            guard width > 0, height > 0 else {
                primaryVideoAspectRatio = 16.0 / 9.0
                return
            }

            primaryVideoAspectRatio = width / height
        } catch {
            primaryVideoAspectRatio = 16.0 / 9.0
        }
    }

    private func installObservers() {
        primaryPeriodicTimeObserver = primaryPlayer.addPeriodicTimeObserver(forInterval: observerInterval, queue: .main) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePlayerTick(isPrimaryTick: true)
            }
        }

        reactionPeriodicTimeObserver = reactionPlayer.addPeriodicTimeObserver(forInterval: observerInterval, queue: .main) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePlayerTick(isPrimaryTick: false)
            }
        }

        let endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let endedItem = notification.object as? AVPlayerItem else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if endedItem === self.primaryPlayer.currentItem || endedItem === self.reactionPlayer.currentItem {
                    self.pause()
                }
            }
        }

        endObservers.append(endObserver)
    }

    private func handlePlayerTick(isPrimaryTick: Bool) {
        if !isPrimaryTick, hasPrimaryVideo, isPrimaryActuallyPlaying {
            return
        }

        updateTimeline()
        refreshPlayingState()
        adjustOffsetForSinglePlayerPause()

        if isPrimaryActuallyPlaying, isReactionActuallyPlaying {
            correctDriftIfNeeded()
        } else {
            normalizeReactionRateIfNeeded()
        }
    }

    private func updateTimeline() {
        let sourceTime: Double
        if hasPrimaryVideo && hasReactionVideo {
            if isPrimaryActuallyPlaying || !isReactionActuallyPlaying {
                sourceTime = primaryPlayer.currentTime().seconds
            } else {
                sourceTime = reactionPlayer.currentTime().seconds
            }
        } else if hasPrimaryVideo {
            sourceTime = primaryPlayer.currentTime().seconds
        } else {
            sourceTime = reactionPlayer.currentTime().seconds
        }

        currentSeconds = sourceTime.isFinite ? max(sourceTime, 0) : 0

        let sourceDuration = hasPrimaryVideo
            ? primaryPlayer.currentItem?.duration.seconds
            : reactionPlayer.currentItem?.duration.seconds

        if let sourceDuration, sourceDuration.isFinite, sourceDuration > 0 {
            durationSeconds = sourceDuration
        } else {
            durationSeconds = max(durationSeconds, 1)
        }
    }

    private func correctDriftIfNeeded() {
        guard hasPrimaryVideo, hasReactionVideo else {
            return
        }

        let primarySeconds = primaryPlayer.currentTime().seconds
        let currentReactionSeconds = reactionPlayer.currentTime().seconds

        guard primarySeconds.isFinite, currentReactionSeconds.isFinite else {
            return
        }

        let desiredReactionSeconds = max(0, primarySeconds - reactionOffsetSeconds)
        let drift = desiredReactionSeconds - currentReactionSeconds

        if abs(drift) >= hardResyncThresholdSeconds {
            let target = CMTime(seconds: desiredReactionSeconds, preferredTimescale: seekTimescale)
            reactionPlayer.seek(to: target, toleranceBefore: correctionSeekTolerance, toleranceAfter: correctionSeekTolerance)
            reactionPlayer.rate = 1.0
            return
        }

        if abs(drift) <= rateCorrectionThresholdSeconds {
            normalizeReactionRateIfNeeded()
            return
        }

        let desiredRate = 1.0 + (drift * rateCorrectionGain)
        let clampedRate = max(1.0 - maxRateAdjustment, min(1.0 + maxRateAdjustment, desiredRate))
        reactionPlayer.rate = Float(clampedRate)
    }

    private var isPrimaryActuallyPlaying: Bool {
        primaryPlayer.timeControlStatus == .playing
    }

    private var isReactionActuallyPlaying: Bool {
        reactionPlayer.timeControlStatus == .playing
    }

    private func refreshPlayingState() {
        isPlaying = isPrimaryActuallyPlaying || isReactionActuallyPlaying
    }

    private func adjustOffsetForSinglePlayerPause() {
        guard hasPrimaryVideo, hasReactionVideo else {
            return
        }

        let primaryPlaying = isPrimaryActuallyPlaying
        let reactionPlaying = isReactionActuallyPlaying

        guard primaryPlaying != reactionPlaying else {
            return
        }

        let primarySeconds = primaryPlayer.currentTime().seconds
        let reactionSeconds = reactionPlayer.currentTime().seconds

        guard primarySeconds.isFinite, reactionSeconds.isFinite else {
            return
        }

        reactionOffsetSeconds = clampReactionOffset(primarySeconds - reactionSeconds)
    }

    private func configurePlayersForSync() {
        // Required for deterministic start times when using setRate(_:time:atHostTime:).
        primaryPlayer.automaticallyWaitsToMinimizeStalling = false
        reactionPlayer.automaticallyWaitsToMinimizeStalling = false
    }

    private func startSynchronizedPlayback(primarySeconds: Double? = nil) {
        guard hasPrimaryVideo, hasReactionVideo else {
            return
        }

        let currentPrimary = primaryPlayer.currentTime().seconds
        let basePrimarySeconds = primarySeconds ?? (currentPrimary.isFinite ? max(currentPrimary, 0) : 0)
        let primaryTime = CMTime(seconds: basePrimarySeconds, preferredTimescale: seekTimescale)
        let reactionTime = reactionTime(forPrimarySeconds: basePrimarySeconds)

        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        let startHost = CMTimeAdd(
            hostNow,
            CMTime(seconds: startLeadTimeSeconds, preferredTimescale: seekTimescale)
        )

        primaryPlayer.setRate(1.0, time: primaryTime, atHostTime: startHost)
        reactionPlayer.setRate(1.0, time: reactionTime, atHostTime: startHost)
    }

    private func normalizeReactionRateIfNeeded() {
        guard isReactionActuallyPlaying else {
            return
        }

        if abs(reactionPlayer.rate - 1.0) > 0.001 {
            reactionPlayer.rate = 1.0
        }
    }

    private func reactionTime(forPrimarySeconds primarySeconds: Double) -> CMTime {
        let target = max(0, primarySeconds - reactionOffsetSeconds)
        return CMTime(seconds: target, preferredTimescale: seekTimescale)
    }

    private func clampReactionOffset(_ value: Double) -> Double {
        min(max(value, minReactionOffsetSeconds), maxReactionOffsetSeconds)
    }

    private func clampVolume(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private func applyVolumeSettings() {
        primaryPlayer.volume = Float(primaryVolume)
        reactionPlayer.volume = Float(reactionVolume)
        primaryPlayer.isMuted = primaryVolume <= 0.001
        reactionPlayer.isMuted = reactionVolume <= 0.001
    }

    private func refreshPrimarySubtitleChoices(for item: AVPlayerItem?) async {
        currentLegibleGroup = nil
        legibleOptionByID = [:]
        subtitleChoices = [.none]
        selectedSubtitleID = SubtitleChoice.noneID

        guard let item else {
            return
        }

        do {
            guard let group = try await item.asset.loadMediaSelectionGroup(for: .legible) else {
                return
            }

            currentLegibleGroup = group

            var choices: [SubtitleChoice] = [.none]
            var optionMap: [String: AVMediaSelectionOption] = [:]

            for (index, option) in group.options.enumerated() {
                let id = "subtitle-\(index)"
                optionMap[id] = option
                choices.append(SubtitleChoice(id: id, title: option.displayName))
            }

            legibleOptionByID = optionMap
            subtitleChoices = choices

            if let selectedOption = item.currentMediaSelection.selectedMediaOption(in: group),
               let selectedID = optionMap.first(where: { $0.value == selectedOption })?.key {
                selectedSubtitleID = selectedID
            } else {
                selectedSubtitleID = SubtitleChoice.noneID
            }
        } catch {
            currentLegibleGroup = nil
            legibleOptionByID = [:]
            subtitleChoices = [.none]
            selectedSubtitleID = SubtitleChoice.noneID
        }

        applySubtitleSelection()
    }

    private func applySubtitleSelection() {
        guard let item = primaryPlayer.currentItem, let group = currentLegibleGroup else {
            return
        }

        if selectedSubtitleID == SubtitleChoice.noneID {
            item.select(nil, in: group)
            return
        }

        guard let option = legibleOptionByID[selectedSubtitleID] else {
            selectedSubtitleID = SubtitleChoice.noneID
            item.select(nil, in: group)
            return
        }

        item.select(option, in: group)
    }

    private func retainSecurityScope(for url: URL) {
        if securityScopedURLs.contains(url) {
            return
        }

        if url.startAccessingSecurityScopedResource() {
            securityScopedURLs.append(url)
        }
    }
}
