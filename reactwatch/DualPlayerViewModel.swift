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
    let maxVolume = 1.0

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
                seekBothPlayers(primarySeconds: clamped, resumePlayback: true)
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

    private func seekBothPlayers(primarySeconds: Double, resumePlayback: Bool) {
        let primaryTarget = CMTime(seconds: max(primarySeconds, 0), preferredTimescale: seekTimescale)
        let reactionTarget = reactionTime(forPrimarySeconds: primarySeconds)

        Task { [weak self] in
            guard let self else { return }
            await self.seekPlayer(self.primaryPlayer, to: primaryTarget)
            await self.seekPlayer(self.reactionPlayer, to: reactionTarget)

            guard resumePlayback else { return }
            self.primaryPlayer.playImmediately(atRate: 1.0)
            self.reactionPlayer.playImmediately(atRate: 1.0)
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

        let primaryStatus = primaryPlayer.timeControlStatus
        let reactionStatus = reactionPlayer.timeControlStatus

        guard (primaryStatus == .playing && reactionStatus == .paused)
            || (primaryStatus == .paused && reactionStatus == .playing) else {
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

        if usesNetworkBackedStream(primaryPlayer.currentItem) || usesNetworkBackedStream(reactionPlayer.currentItem) {
            // Host-time rate scheduling is less reliable for remote adaptive streams during scrubs.
            primaryPlayer.seek(to: primaryTime, toleranceBefore: .zero, toleranceAfter: .zero)
            reactionPlayer.seek(to: reactionTime, toleranceBefore: .zero, toleranceAfter: .zero)
            primaryPlayer.playImmediately(atRate: 1.0)
            reactionPlayer.playImmediately(atRate: 1.0)
            return
        }

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
        min(max(value, 0), maxVolume)
    }

    private func usesNetworkBackedStream(_ item: AVPlayerItem?) -> Bool {
        guard let asset = item?.asset as? AVURLAsset else {
            return false
        }
        return !asset.url.isFileURL
    }

    private func resolvePlayableURLIfNeeded(from url: URL) async throws -> URL {
        if isYouTubeURL(url) {
            throw URLImportError.unsupportedPageURL("YouTube")
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
        case unsupportedPageURL(String)

        var errorDescription: String? {
            switch self {
            case .invalidVimeoURL:
                return "This Vimeo URL format is not recognized."
            case .unreachableURL:
                return "Could not reach the URL."
            case .vimeoResolutionFailed:
                return "Could not extract a playable stream from this Vimeo link."
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
