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
    let reactionYouTubeBridge = YouTubePlayerBridge()

    @Published var primaryTitle = "No show/movie selected"
    @Published var reactionTitle = "No reaction selected"
    @Published var hasPrimaryVideo = false
    @Published var hasReactionVideo = false
    @Published var reactionYouTubeVideoID: String?
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
    let maxVolume = 1.0

    var isReactionYouTube: Bool {
        reactionYouTubeVideoID != nil
    }

    var canMatchCurrentFrames: Bool {
        hasPrimaryVideo && hasReactionVideo
    }

    private var primaryPeriodicTimeObserver: Any?
    private var reactionPeriodicTimeObserver: Any?
    private var endObservers: [NSObjectProtocol] = []
    private var securityScopedURLs: [URL] = []
    private var currentLegibleGroup: AVMediaSelectionGroup?
    private var legibleOptionByID: [String: AVMediaSelectionOption] = [:]
    private var playbackStatusCancellables: Set<AnyCancellable> = []
    private var lastPrimaryPlaybackStatus: PlaybackStatus = .paused
    private var lastReactionPlaybackStatus: PlaybackStatus = .paused
    private var reactionYouTubeState: YouTubePlayerBridge.PlayerState = .unstarted
    private var reactionYouTubeCurrentSeconds = 0.0
    private var reactionYouTubeDurationSeconds = 0.0
    private var lastYouTubeCorrectionDate = Date.distantPast

    private let observerInterval = CMTime(seconds: 0.1, preferredTimescale: 600)
    private let seekTimescale: CMTimeScale = 600
    private let hardResyncThresholdSeconds = 0.45
    private let rateCorrectionThresholdSeconds = 0.03
    private let maxRateAdjustment = 0.06
    private let rateCorrectionGain = 0.35
    private let correctionSeekTolerance = CMTime(seconds: 0.02, preferredTimescale: 600)
    private let youTubeResyncThresholdSeconds = 1.2
    private let minimumYouTubeCorrectionInterval = 2.5

    init() {
        configurePlayersForSync()
        configureYouTubeBridge()
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

    func importFromURLString(_ rawURL: String, kind: VideoKind) {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            alertMessage = "Please enter a valid URL."
            return
        }

        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            alertMessage = "Enter a valid http(s) URL."
            return
        }

        Task { [weak self] in
            guard let self else { return }

            do {
                if kind == .reaction, let videoID = self.extractYouTubeVideoID(from: url) {
                    self.loadYouTubeReaction(videoID: videoID, title: url.absoluteString)
                    return
                }

                let resolvedURL = try await self.resolvePlayableURLIfNeeded(from: url)
                await self.loadVideo(at: resolvedURL, kind: kind)
            } catch {
                self.alertMessage = error.localizedDescription
            }
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
            playReaction()
        }

        isPlaying = true
    }

    func pause() {
        primaryPlayer.pause()
        pauseReaction()
        isPlaying = false
    }

    func skip(by deltaSeconds: Double) {
        seek(to: currentSeconds + deltaSeconds)
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, max(durationSeconds, 0)))
        currentSeconds = clamped

        if hasPrimaryVideo, hasReactionVideo {
            seekBothPlayers(primarySeconds: clamped, resumePlayback: isPlaying)
            return
        }

        if hasPrimaryVideo {
            let primaryTarget = CMTime(seconds: clamped, preferredTimescale: seekTimescale)
            primaryPlayer.seek(to: primaryTarget, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        if hasReactionVideo {
            if hasPrimaryVideo {
                seekReactionToMatchPrimaryTime(clamped)
            } else {
                seekReaction(to: clamped)
            }
        }

        if isPlaying {
            if hasPrimaryVideo {
                primaryPlayer.playImmediately(atRate: 1.0)
            } else if hasReactionVideo {
                playReaction()
            }
        }
    }

    private func seekBothPlayers(primarySeconds: Double, resumePlayback: Bool) {
        let primaryTarget = CMTime(seconds: max(primarySeconds, 0), preferredTimescale: seekTimescale)
        let reactionTarget = reactionSeconds(forPrimarySeconds: primarySeconds)

        Task { [weak self] in
            guard let self else { return }
            await self.seekPlayer(self.primaryPlayer, to: primaryTarget)
            self.seekReaction(to: reactionTarget)

            guard resumePlayback else { return }
            self.primaryPlayer.playImmediately(atRate: 1.0)
            self.playReaction()
            self.isPlaying = true
        }
    }

    private func seekPlayer(_ player: AVPlayer, to time: CMTime) async {
        await withCheckedContinuation { continuation in
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                continuation.resume()
            }
        }
    }

    func realignReactionToPrimary() {
        guard hasReactionVideo else {
            return
        }

        let primarySeconds = hasPrimaryVideo ? primaryPlayer.currentTime().seconds : 0
        let reactionTarget = reactionSeconds(forPrimarySeconds: primarySeconds)

        if hasPrimaryVideo, isPrimaryActuallyPlaying, isReactionActuallyPlaying {
            startSynchronizedPlayback(primarySeconds: primarySeconds)
        } else {
            seekReaction(to: reactionTarget)
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
            setPrimaryVolume(to: maxVolume)
        } else {
            setPrimaryVolume(to: 0)
        }
    }

    func toggleReactionMute() {
        if reactionVolume <= 0.001 {
            setReactionVolume(to: maxVolume)
        } else {
            setReactionVolume(to: 0)
        }
    }

    func matchOffsetToCurrentFrames() {
        guard hasPrimaryVideo, hasReactionVideo else {
            return
        }

        let primarySeconds = primaryPlayer.currentTime().seconds
        let reactionSeconds = currentReactionSeconds

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
            } else if !url.isFileURL, isLikelyHostedVideoPage(url) {
                alertMessage = "This appears to be a YouTube/Vimeo page URL. AVPlayer can only play direct media streams (for example .m3u8/.mp4)."
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
            clearYouTubeReactionState()
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

        primaryPlayer.publisher(for: \.timeControlStatus)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.synchronizeStateFromTick()
            }
            .store(in: &playbackStatusCancellables)

        reactionPlayer.publisher(for: \.timeControlStatus)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.synchronizeStateFromTick()
            }
            .store(in: &playbackStatusCancellables)

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

        synchronizeStateFromTick()
    }

    private func synchronizeStateFromTick() {
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
                sourceTime = currentReactionSeconds
            }
        } else if hasPrimaryVideo {
            sourceTime = primaryPlayer.currentTime().seconds
        } else {
            sourceTime = currentReactionSeconds
        }

        currentSeconds = sourceTime.isFinite ? max(sourceTime, 0) : 0

        let sourceDuration: Double? = if hasPrimaryVideo {
            primaryPlayer.currentItem?.duration.seconds
        } else if isReactionYouTube {
            reactionYouTubeDurationSeconds
        } else {
            reactionPlayer.currentItem?.duration.seconds
        }

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
        let reactionSecondsNow = currentReactionSeconds

        guard primarySeconds.isFinite, reactionSecondsNow.isFinite else {
            return
        }

        let desiredReactionSeconds = reactionSeconds(forPrimarySeconds: primarySeconds)
        let drift = desiredReactionSeconds - reactionSecondsNow

        if isReactionYouTube {
            // YouTube time callbacks are quantized and seek operations are expensive.
            // Keep correction coarse so playback stays smooth.
            guard abs(drift) >= youTubeResyncThresholdSeconds else {
                return
            }

            let now = Date()
            guard now.timeIntervalSince(lastYouTubeCorrectionDate) >= minimumYouTubeCorrectionInterval else {
                return
            }

            seekReaction(to: desiredReactionSeconds)
            lastYouTubeCorrectionDate = now
            return
        }

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
        switch reactionPlaybackStatus {
        case .playing:
            return true
        case .paused, .waiting:
            return false
        }
    }

    private func refreshPlayingState() {
        let primaryStatus = primaryPlaybackStatus
        let reactionStatus = reactionPlaybackStatus

        maybeFinalizeOffsetForIndependentPause(
            previousPrimary: lastPrimaryPlaybackStatus,
            previousReaction: lastReactionPlaybackStatus,
            currentPrimary: primaryStatus,
            currentReaction: reactionStatus
        )

        lastPrimaryPlaybackStatus = primaryStatus
        lastReactionPlaybackStatus = reactionStatus
        isPlaying = primaryStatus == .playing || reactionStatus == .playing
    }

    private func maybeFinalizeOffsetForIndependentPause(
        previousPrimary: PlaybackStatus,
        previousReaction: PlaybackStatus,
        currentPrimary: PlaybackStatus,
        currentReaction: PlaybackStatus
    ) {
        guard hasPrimaryVideo, hasReactionVideo else {
            return
        }

        guard currentPrimary == .paused, currentReaction == .paused else {
            return
        }

        let wasOneSidePlaying = (previousPrimary == .playing && previousReaction != .playing)
            || (previousReaction == .playing && previousPrimary != .playing)
        guard wasOneSidePlaying else {
            return
        }

        applyOffsetFromCurrentFramesWithoutRealign()
    }

    private func adjustOffsetForSinglePlayerPause() {
        guard hasPrimaryVideo, hasReactionVideo else {
            return
        }

        let primaryStatus = primaryPlaybackStatus
        let reactionStatus = reactionPlaybackStatus

        guard (primaryStatus == .playing && reactionStatus == .paused)
            || (primaryStatus == .paused && reactionStatus == .playing) else {
            return
        }

        let primarySeconds = primaryPlayer.currentTime().seconds
        let reactionSeconds = currentReactionSeconds

        guard primarySeconds.isFinite, reactionSeconds.isFinite else {
            return
        }

        reactionOffsetSeconds = clampReactionOffset(primarySeconds - reactionSeconds)
    }

    private func applyOffsetFromCurrentFramesWithoutRealign() {
        let primarySeconds = primaryPlayer.currentTime().seconds
        let reactionSeconds = currentReactionSeconds

        guard primarySeconds.isFinite, reactionSeconds.isFinite else {
            return
        }

        reactionOffsetSeconds = clampReactionOffset(primarySeconds - reactionSeconds)
    }

    private func configurePlayersForSync() {
        // Favor immediate starts and let drift correction keep players aligned.
        primaryPlayer.automaticallyWaitsToMinimizeStalling = false
        reactionPlayer.automaticallyWaitsToMinimizeStalling = false
    }

    private func startSynchronizedPlayback(primarySeconds: Double? = nil) {
        guard hasPrimaryVideo, hasReactionVideo else {
            return
        }

        let currentPrimary = primaryPlayer.currentTime().seconds
        let basePrimarySeconds = primarySeconds ?? (currentPrimary.isFinite ? max(currentPrimary, 0) : 0)
        seekBothPlayers(primarySeconds: basePrimarySeconds, resumePlayback: true)
    }

    private func normalizeReactionRateIfNeeded() {
        guard !isReactionYouTube else {
            return
        }

        guard isReactionActuallyPlaying else {
            return
        }

        if abs(reactionPlayer.rate - 1.0) > 0.001 {
            reactionPlayer.rate = 1.0
        }
    }

    private func reactionSeconds(forPrimarySeconds primarySeconds: Double) -> Double {
        max(0, primarySeconds - reactionOffsetSeconds)
    }

    private func clampReactionOffset(_ value: Double) -> Double {
        min(max(value, minReactionOffsetSeconds), maxReactionOffsetSeconds)
    }

    private func clampVolume(_ value: Double) -> Double {
        min(max(value, 0), maxVolume)
    }

    private enum PlaybackStatus {
        case playing
        case paused
        case waiting
    }

    private var primaryPlaybackStatus: PlaybackStatus {
        switch primaryPlayer.timeControlStatus {
        case .playing:
            return .playing
        case .paused:
            return .paused
        case .waitingToPlayAtSpecifiedRate:
            return .waiting
        @unknown default:
            return .waiting
        }
    }

    private var reactionPlaybackStatus: PlaybackStatus {
        if isReactionYouTube {
            switch reactionYouTubeState {
            case .playing:
                return .playing
            case .paused, .ended, .cued:
                return .paused
            case .unstarted, .buffering, .unknown:
                return .waiting
            }
        }

        switch reactionPlayer.timeControlStatus {
        case .playing:
            return .playing
        case .paused:
            return .paused
        case .waitingToPlayAtSpecifiedRate:
            return .waiting
        @unknown default:
            return .waiting
        }
    }

    private var currentReactionSeconds: Double {
        if isReactionYouTube {
            return reactionYouTubeCurrentSeconds
        }
        return reactionPlayer.currentTime().seconds
    }

    private func playReaction() {
        if isReactionYouTube {
            reactionYouTubeBridge.play()
        } else {
            reactionPlayer.playImmediately(atRate: 1.0)
        }
    }

    private func pauseReaction() {
        if isReactionYouTube {
            reactionYouTubeBridge.pause()
        } else {
            reactionPlayer.pause()
        }
    }

    private func seekReaction(to seconds: Double) {
        let target = max(0, seconds)
        if isReactionYouTube {
            reactionYouTubeBridge.seek(to: target, allowSeekAhead: true)
        } else {
            let time = CMTime(seconds: target, preferredTimescale: seekTimescale)
            reactionPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func seekReactionToMatchPrimaryTime(_ primarySeconds: Double) {
        seekReaction(to: reactionSeconds(forPrimarySeconds: primarySeconds))
    }

    private func configureYouTubeBridge() {
        reactionYouTubeBridge.onReady = { [weak self] in
            guard let self else { return }
            self.reactionYouTubeBridge.setVolume(self.reactionVolume)
        }

        reactionYouTubeBridge.onStateChange = { [weak self] state in
            guard let self else { return }
            self.reactionYouTubeState = state
            if state == .ended {
                self.pause()
            } else {
                self.synchronizeStateFromTick()
            }
        }

        reactionYouTubeBridge.onTimeUpdate = { [weak self] current, duration in
            guard let self else { return }
            self.reactionYouTubeCurrentSeconds = current
            if duration.isFinite, duration > 0 {
                self.reactionYouTubeDurationSeconds = duration
            }
            self.synchronizeStateFromTick()
        }

        reactionYouTubeBridge.onError = { [weak self] code in
            self?.alertMessage = self?.messageForYouTubeError(code)
        }
    }

    private func messageForYouTubeError(_ code: Int) -> String {
        switch code {
        case 2:
            return "YouTube could not load this URL (invalid video ID)."
        case 5:
            return "YouTube playback failed in this WebView session."
        case 100:
            return "This YouTube video is unavailable or private."
        case 101, 150:
            return "The video owner has disabled embedding for this YouTube video."
        case 153:
            return "YouTube rejected the embed request (missing app referrer identity). Please retry after reopening the app."
        default:
            return "YouTube player error (\(code))."
        }
    }

    private func loadYouTubeReaction(videoID: String, title: String) {
        pauseReaction()
        reactionPlayer.pause()
        reactionPlayer.replaceCurrentItem(with: nil)

        let primaryReferenceSeconds = hasPrimaryVideo ? primaryPlayer.currentTime().seconds : 0
        let finitePrimaryReference = primaryReferenceSeconds.isFinite ? max(primaryReferenceSeconds, 0) : 0

        reactionYouTubeCurrentSeconds = 0
        reactionYouTubeDurationSeconds = 0
        reactionYouTubeState = .unstarted
        reactionYouTubeVideoID = videoID
        reactionTitle = title
        hasReactionVideo = true
        reactionYouTubeBridge.load(videoID: videoID)
        reactionYouTubeBridge.setVolume(reactionVolume)
        seekReaction(to: reactionSeconds(forPrimarySeconds: finitePrimaryReference))
        pauseReaction()

        updateTimeline()
        refreshPlayingState()
    }

    private func clearYouTubeReactionState() {
        guard isReactionYouTube else {
            return
        }
        reactionYouTubeBridge.stop()
        reactionYouTubeVideoID = nil
        reactionYouTubeCurrentSeconds = 0
        reactionYouTubeDurationSeconds = 0
        reactionYouTubeState = .unstarted
    }

    private func extractYouTubeVideoID(from url: URL) -> String? {
        let host = (url.host ?? "").lowercased()
        let components = url.pathComponents.filter { $0 != "/" }

        if host == "youtu.be" || host.hasSuffix(".youtu.be") {
            return normalizeYouTubeVideoID(components.first)
        }

        guard host.contains("youtube.com") else {
            return nil
        }

        if let urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let value = urlComponents.queryItems?.first(where: { $0.name == "v" })?.value,
           let videoID = normalizeYouTubeVideoID(value) {
            return videoID
        }

        if let embedIndex = components.firstIndex(where: { $0 == "embed" || $0 == "shorts" || $0 == "live" }),
           components.indices.contains(embedIndex + 1) {
            return normalizeYouTubeVideoID(components[embedIndex + 1])
        }

        return nil
    }

    private func normalizeYouTubeVideoID(_ raw: String?) -> String? {
        guard let raw else {
            return nil
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cleaned = raw.unicodeScalars.filter { allowed.contains($0) }.map(String.init).joined()
        guard cleaned.count == 11 else {
            return nil
        }
        return cleaned
    }

    private func resolvePlayableURLIfNeeded(from url: URL) async throws -> URL {
        if isYouTubeURL(url) {
            throw URLImportError.unsupportedYouTubeURL
        }

        if isVimeoURL(url), !isLikelyDirectMediaURL(url) {
            return try await resolveVimeoStreamURL(from: url)
        }

        return url
    }

    private func resolveVimeoStreamURL(from sourceURL: URL) async throws -> URL {
        guard let playerURL = makeVimeoPlayerURL(from: sourceURL) else {
            throw URLImportError.invalidVimeoURL
        }

        let (data, response) = try await URLSession.shared.data(from: playerURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLImportError.unreachableURL
        }

        guard let html = String(data: data, encoding: .utf8),
              let playerConfigJSON = extractJSONAssigned(to: "window.playerConfig = ", from: html),
              let jsonData = playerConfigJSON.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw URLImportError.vimeoResolutionFailed
        }

        var candidates: [URL] = []
        candidates.append(contentsOf: extractVimeoHLSURLs(root))
        candidates.append(contentsOf: extractVimeoProgressiveURLs(root))
        candidates = deduplicated(candidates)

        guard !candidates.isEmpty else {
            throw URLImportError.vimeoResolutionFailed
        }

        return await selectReachableURL(from: candidates) ?? candidates[0]
    }

    private func extractVimeoHLSURLs(_ root: [String: Any]) -> [URL] {
        guard let request = root["request"] as? [String: Any],
              let files = request["files"] as? [String: Any],
              let hls = files["hls"] as? [String: Any],
              let cdns = hls["cdns"] as? [String: Any] else {
            return []
        }

        let orderedCDNKeys = orderedVimeoCDNKeys(
            defaultCDN: hls["default_cdn"] as? String,
            available: Array(cdns.keys)
        )

        var urls: [URL] = []
        for key in orderedCDNKeys {
            guard let cdn = cdns[key] as? [String: Any] else {
                continue
            }
            urls.append(contentsOf: extractPlayableURLs(from: cdn))
        }

        return deduplicated(urls)
    }

    private func orderedVimeoCDNKeys(defaultCDN: String?, available: [String]) -> [String] {
        available.sorted {
            cdnPriority($0, defaultCDN: defaultCDN) < cdnPriority($1, defaultCDN: defaultCDN)
        }
    }

    private func cdnPriority(_ key: String, defaultCDN: String?) -> Int {
        if key.contains("skyfire") { return 0 }
        if key == defaultCDN { return 1 }
        if key.contains("fastly") { return 2 }
        if key.contains("akfire") { return 3 }
        return 4
    }

    private func extractPlayableURLs(from dictionary: [String: Any]) -> [URL] {
        var urls: [URL] = []
        for key in ["url", "avc_url"] {
            guard let urlString = dictionary[key] as? String,
                  let url = URL(string: urlString) else {
                continue
            }
            urls.append(url)
        }
        return urls
    }

    private func extractVimeoProgressiveURLs(_ root: [String: Any]) -> [URL] {
        guard let request = root["request"] as? [String: Any],
              let files = request["files"] as? [String: Any],
              let progressive = files["progressive"] as? [[String: Any]] else {
            return []
        }

        let sorted = progressive.sorted { lhs, rhs in
            let leftHeight = lhs["height"] as? Int ?? 0
            let rightHeight = rhs["height"] as? Int ?? 0
            return leftHeight > rightHeight
        }

        var urls: [URL] = []
        for item in sorted {
            guard let urlString = item["url"] as? String,
                  let url = URL(string: urlString) else {
                continue
            }
            urls.append(url)
        }
        return deduplicated(urls)
    }

    private func deduplicated(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var unique: [URL] = []
        for url in urls {
            let key = url.absoluteString
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(url)
        }
        return unique
    }

    private func selectReachableURL(from candidates: [URL]) async -> URL? {
        for candidate in candidates {
            if await isReachable(candidate) {
                return candidate
            }
        }
        return nil
    }

    private func isReachable(_ url: URL) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "HEAD"

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) {
                return true
            }
        } catch {
            // Some Vimeo endpoints reject HEAD.
        }

        guard url.pathExtension.lowercased() == "m3u8" else {
            return false
        }

        var fallback = URLRequest(url: url, timeoutInterval: 8)
        fallback.httpMethod = "GET"
        fallback.setValue("bytes=0-1024", forHTTPHeaderField: "Range")

        do {
            let (_, response) = try await URLSession.shared.data(for: fallback)
            if let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) {
                return true
            }
        } catch {
            return false
        }

        return false
    }

    private func extractJSONAssigned(to marker: String, from html: String) -> String? {
        guard let markerRange = html.range(of: marker),
              let objectStart = html[markerRange.upperBound...].firstIndex(of: "{") else {
            return nil
        }

        var depth = 0
        var inString = false
        var escaping = false
        var index = objectStart

        while index < html.endIndex {
            let ch = html[index]

            if inString {
                if escaping {
                    escaping = false
                } else if ch == "\\" {
                    escaping = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                if ch == "\"" {
                    inString = true
                } else if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(html[objectStart...index])
                    }
                }
            }

            index = html.index(after: index)
        }

        return nil
    }

    private func makeVimeoPlayerURL(from sourceURL: URL) -> URL? {
        let host = (sourceURL.host ?? "").lowercased()
        let components = sourceURL.pathComponents.filter { $0 != "/" }
        let queryItems = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)?.queryItems
        let hashFromQuery = queryItems?.first(where: { $0.name == "h" })?.value

        if host.contains("player.vimeo.com") {
            guard let videoIndex = components.firstIndex(of: "video"),
                  components.indices.contains(videoIndex + 1) else {
                return nil
            }

            let id = components[videoIndex + 1]
            guard id.allSatisfy(\.isNumber) else { return nil }
            return buildVimeoPlayerURL(id: id, hash: hashFromQuery)
        }

        guard host.contains("vimeo.com") else {
            return nil
        }

        guard let idIndex = components.firstIndex(where: { $0.allSatisfy(\.isNumber) }) else {
            return nil
        }

        let id = components[idIndex]
        let pathHash: String? = {
            let nextIndex = idIndex + 1
            guard components.indices.contains(nextIndex) else { return nil }
            let candidate = components[nextIndex]
            return candidate.allSatisfy(\.isNumber) ? nil : candidate
        }()

        return buildVimeoPlayerURL(id: id, hash: hashFromQuery ?? pathHash)
    }

    private func buildVimeoPlayerURL(id: String, hash: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "player.vimeo.com"
        components.path = "/video/\(id)"
        if let hash, !hash.isEmpty {
            components.queryItems = [URLQueryItem(name: "h", value: hash)]
        }
        return components.url
    }

    private func isVimeoURL(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        return host.contains("vimeo.com")
    }

    private func isYouTubeURL(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        return host.contains("youtube.com") || host.contains("youtu.be")
    }

    private func isLikelyDirectMediaURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "mp4" || ext == "m3u8" || ext == "mov"
    }

    private func isLikelyHostedVideoPage(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        return host.contains("youtube.com")
            || host.contains("youtu.be")
            || host.contains("vimeo.com")
    }

    private enum URLImportError: LocalizedError {
        case invalidVimeoURL
        case unreachableURL
        case vimeoResolutionFailed
        case unsupportedYouTubeURL
        case unsupportedPageURL(String)

        var errorDescription: String? {
            switch self {
            case .invalidVimeoURL:
                return "This Vimeo URL format is not recognized."
            case .unreachableURL:
                return "Could not reach the URL."
            case .vimeoResolutionFailed:
                return "Could not extract a playable stream from this Vimeo link."
            case .unsupportedYouTubeURL:
                return "Could not parse this YouTube link. Paste a standard URL like youtube.com/watch?v=... or youtu.be/..."
            case let .unsupportedPageURL(provider):
                return "\(provider) page URLs are not directly playable. Paste a direct media stream URL instead."
            }
        }
    }

    private func applyVolumeSettings() {
        primaryPlayer.volume = Float(primaryVolume)
        reactionPlayer.volume = Float(reactionVolume)
        primaryPlayer.isMuted = primaryVolume <= 0.001
        reactionPlayer.isMuted = reactionVolume <= 0.001
        reactionYouTubeBridge.setVolume(reactionVolume)
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
