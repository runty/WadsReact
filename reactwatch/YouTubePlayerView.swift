import SwiftUI
import WebKit

final class YouTubePlayerBridge {
    enum PlayerState: Equatable {
        case unstarted
        case ended
        case playing
        case paused
        case buffering
        case cued
        case unknown(Int)
    }

    fileprivate enum Command {
        case load(String)
        case play
        case pause
        case seek(seconds: Double, allowSeekAhead: Bool)
        case setVolume(Double)
        case stop
    }

    var onReady: (() -> Void)?
    var onStateChange: ((PlayerState) -> Void)?
    var onTimeUpdate: ((Double, Double) -> Void)?
    var onError: ((Int) -> Void)?

    fileprivate var commandSink: ((Command) -> Void)?

    func load(videoID: String) {
        commandSink?(.load(videoID))
    }

    func play() {
        commandSink?(.play)
    }

    func pause() {
        commandSink?(.pause)
    }

    func seek(to seconds: Double, allowSeekAhead: Bool = true) {
        commandSink?(.seek(seconds: max(seconds, 0), allowSeekAhead: allowSeekAhead))
    }

    func setVolume(_ normalizedVolume: Double) {
        commandSink?(.setVolume(min(max(normalizedVolume, 0), 1)))
    }

    func stop() {
        commandSink?(.stop)
    }

    fileprivate func emitReady() {
        onReady?()
    }

    fileprivate func emitState(_ state: PlayerState) {
        onStateChange?(state)
    }

    fileprivate func emitTime(current: Double, duration: Double) {
        onTimeUpdate?(max(current, 0), max(duration, 0))
    }

    fileprivate func emitError(_ code: Int) {
        onError?(code)
    }
}

struct YouTubePlayerSurfaceView: View {
    let bridge: YouTubePlayerBridge
    let videoID: String
    let showsNativeControls: Bool

    var body: some View {
        PlatformYouTubePlayerRepresentable(
            bridge: bridge,
            videoID: videoID,
            showsNativeControls: showsNativeControls
        )
            .background(Color.black)
            .clipped()
    }
}

private final class YouTubePlayerCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private enum EventKind: String {
        case ready
        case state
        case time
        case error
    }

    private let bridge: YouTubePlayerBridge
    private weak var webView: WKWebView?
    private var currentVideoID: String?
    private var pendingVideoID: String?
    private var pendingCommands: [YouTubePlayerBridge.Command] = []
    private var showsNativeControls: Bool
    private var isReady = false

    private let messageHandlerName = "ytBridge"

    init(bridge: YouTubePlayerBridge, initialVideoID: String, showsNativeControls: Bool) {
        self.bridge = bridge
        pendingVideoID = initialVideoID
        self.showsNativeControls = showsNativeControls
        super.init()

        bridge.commandSink = { [weak self] command in
            self?.handle(command)
        }
    }

    deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: messageHandlerName)
    }

    func connect(webView: WKWebView) {
        self.webView = webView
        webView.navigationDelegate = self

#if os(iOS) || os(visionOS)
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
#elseif os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
#endif

        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: messageHandlerName)
        controller.add(self, name: messageHandlerName)

        let initialID = pendingVideoID ?? currentVideoID ?? ""
        let identityURL = Self.embedderIdentityURL()
        let html = Self.playerHTML(
            initialVideoID: initialID,
            embedderIdentityURL: identityURL,
            showsNativeControls: showsNativeControls
        )
        webView.loadHTMLString(html, baseURL: identityURL)
    }

    func updateVideoID(_ videoID: String) {
        guard currentVideoID != videoID else {
            return
        }
        handle(.load(videoID))
    }

    func updateControls(_ showsNativeControls: Bool) {
        guard self.showsNativeControls != showsNativeControls else {
            return
        }
        self.showsNativeControls = showsNativeControls
        isReady = false
        pendingCommands.removeAll(keepingCapacity: true)
        if let webView {
            connect(webView: webView)
        }
    }

    private func handle(_ command: YouTubePlayerBridge.Command) {
        switch command {
        case let .load(videoID):
            let sanitized = Self.sanitizeVideoID(videoID)
            pendingVideoID = sanitized
            if isReady {
                currentVideoID = sanitized
                runJavaScript("window.reactwatchLoadVideo('\(Self.escapeForSingleQuotedJS(sanitized))');")
            }
        case .play:
            enqueueOrRun(command, js: "window.reactwatchPlay();")
        case .pause:
            enqueueOrRun(command, js: "window.reactwatchPause();")
        case let .seek(seconds, allowSeekAhead):
            let allow = allowSeekAhead ? "true" : "false"
            let js = "window.reactwatchSeek(\(seconds), \(allow));"
            enqueueOrRun(command, js: js)
        case let .setVolume(normalized):
            let bounded = min(max(normalized, 0), 1)
            let jsVolume = Int((bounded * 100).rounded())
            enqueueOrRun(command, js: "window.reactwatchSetVolume(\(jsVolume));")
        case .stop:
            enqueueOrRun(command, js: "window.reactwatchStop();")
        }
    }

    private func enqueueOrRun(_ command: YouTubePlayerBridge.Command, js: String) {
        guard isReady else {
            pendingCommands.append(command)
            return
        }
        runJavaScript(js)
    }

    private func flushPendingIfReady() {
        guard isReady else {
            return
        }

        if let pendingVideoID {
            currentVideoID = pendingVideoID
            runJavaScript("window.reactwatchLoadVideo('\(Self.escapeForSingleQuotedJS(pendingVideoID))');")
            self.pendingVideoID = nil
        }

        let commands = pendingCommands
        pendingCommands.removeAll(keepingCapacity: true)
        for command in commands {
            handle(command)
        }
    }

    private func runJavaScript(_ script: String) {
        webView?.evaluateJavaScript(script) { _, error in
            if let error {
                print("YouTube JS error: \(error.localizedDescription)")
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == messageHandlerName,
              let body = message.body as? [String: Any],
              let rawKind = body["kind"] as? String,
              let kind = EventKind(rawValue: rawKind) else {
            return
        }

        switch kind {
        case .ready:
            isReady = true
            bridge.emitReady()
            flushPendingIfReady()
        case .state:
            let raw = body["value"] as? Int ?? -999
            bridge.emitState(Self.mapState(raw))
        case .time:
            let current = body["current"] as? Double ?? 0
            let duration = body["duration"] as? Double ?? 0
            bridge.emitTime(current: current, duration: duration)
        case .error:
            let code = body["value"] as? Int ?? -1
            bridge.emitError(code)
        }
    }

    private static func embedderIdentityURL() -> URL {
        let fallback = URL(string: "https://reactwatch.app")!
        guard let bundleID = Bundle.main.bundleIdentifier?.lowercased(), !bundleID.isEmpty else {
            return fallback
        }
        return URL(string: "https://\(bundleID)") ?? fallback
    }

    private static func mapState(_ value: Int) -> YouTubePlayerBridge.PlayerState {
        switch value {
        case -1: return .unstarted
        case 0: return .ended
        case 1: return .playing
        case 2: return .paused
        case 3: return .buffering
        case 5: return .cued
        default: return .unknown(value)
        }
    }

    private static func sanitizeVideoID(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return raw.unicodeScalars.filter { allowed.contains($0) }.map(String.init).joined()
    }

    private static func escapeForSingleQuotedJS(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    private static func playerHTML(
        initialVideoID: String,
        embedderIdentityURL: URL,
        showsNativeControls: Bool
    ) -> String {
        let escapedVideoID = escapeForSingleQuotedJS(sanitizeVideoID(initialVideoID))
        let escapedOrigin = escapeForSingleQuotedJS(embedderIdentityURL.absoluteString)
        let controlsValue = showsNativeControls ? "1" : "0"
        return """
        <!doctype html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <meta name="referrer" content="strict-origin-when-cross-origin">
            <style>
                html, body, #player {
                    margin: 0;
                    padding: 0;
                    width: 100%;
                    height: 100%;
                    background: #000;
                    overflow: hidden;
                }
            </style>
        </head>
        <body>
            <div id="player"></div>
            <script>
                let reactwatchPlayer = null;
                let reactwatchPendingVideoId = '\(escapedVideoID)';
                const reactwatchOrigin = '\(escapedOrigin)';

                function reactwatchSend(kind, payload) {
                    const message = Object.assign({ kind: kind }, payload || {});
                    window.webkit.messageHandlers.ytBridge.postMessage(message);
                }

                function onYouTubeIframeAPIReady() {
                    reactwatchPlayer = new YT.Player('player', {
                        videoId: reactwatchPendingVideoId,
                        playerVars: {
                            autoplay: 0,
                            controls: \(controlsValue),
                            enablejsapi: 1,
                            rel: 0,
                            fs: 0,
                            iv_load_policy: 3,
                            modestbranding: 1,
                            disablekb: 1,
                            playsinline: 1,
                            origin: reactwatchOrigin,
                            widget_referrer: reactwatchOrigin
                        },
                        events: {
                            onReady: onReactwatchPlayerReady,
                            onStateChange: onReactwatchPlayerStateChange,
                            onError: onReactwatchPlayerError
                        }
                    });
                }

                function onReactwatchPlayerReady() {
                    reactwatchSend('ready', {});
                    setInterval(() => {
                        if (!reactwatchPlayer || typeof reactwatchPlayer.getCurrentTime !== 'function') {
                            return;
                        }
                        const current = reactwatchPlayer.getCurrentTime() || 0;
                        const duration = reactwatchPlayer.getDuration() || 0;
                        reactwatchSend('time', { current: current, duration: duration });
                    }, 200);
                }

                function onReactwatchPlayerStateChange(event) {
                    reactwatchSend('state', { value: event.data });
                }

                function onReactwatchPlayerError(event) {
                    reactwatchSend('error', { value: event.data });
                }

                window.reactwatchLoadVideo = function(videoId) {
                    reactwatchPendingVideoId = videoId;
                    if (reactwatchPlayer && typeof reactwatchPlayer.cueVideoById === 'function') {
                        reactwatchPlayer.cueVideoById({ videoId: videoId, startSeconds: 0, suggestedQuality: 'default' });
                    }
                };

                window.reactwatchPlay = function() {
                    if (reactwatchPlayer && typeof reactwatchPlayer.playVideo === 'function') {
                        reactwatchPlayer.playVideo();
                    }
                };

                window.reactwatchPause = function() {
                    if (reactwatchPlayer && typeof reactwatchPlayer.pauseVideo === 'function') {
                        reactwatchPlayer.pauseVideo();
                    }
                };

                window.reactwatchSeek = function(seconds, allowSeekAhead) {
                    if (reactwatchPlayer && typeof reactwatchPlayer.seekTo === 'function') {
                        reactwatchPlayer.seekTo(seconds, allowSeekAhead);
                    }
                };

                window.reactwatchSetVolume = function(volume) {
                    if (reactwatchPlayer && typeof reactwatchPlayer.setVolume === 'function') {
                        reactwatchPlayer.setVolume(volume);
                    }
                };

                window.reactwatchStop = function() {
                    if (reactwatchPlayer && typeof reactwatchPlayer.pauseVideo === 'function') {
                        reactwatchPlayer.pauseVideo();
                    }
                };

                const reactwatchScript = document.createElement('script');
                reactwatchScript.src = 'https://www.youtube.com/iframe_api';
                const firstScriptTag = document.getElementsByTagName('script')[0];
                firstScriptTag.parentNode.insertBefore(reactwatchScript, firstScriptTag);
            </script>
        </body>
        </html>
        """
    }
}

#if os(iOS) || os(visionOS)
import UIKit

private struct PlatformYouTubePlayerRepresentable: UIViewRepresentable {
    let bridge: YouTubePlayerBridge
    let videoID: String
    let showsNativeControls: Bool

    func makeCoordinator() -> YouTubePlayerCoordinator {
        YouTubePlayerCoordinator(
            bridge: bridge,
            initialVideoID: videoID,
            showsNativeControls: showsNativeControls
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = makeConfiguredWebView()
        context.coordinator.connect(webView: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.updateVideoID(videoID)
        context.coordinator.updateControls(showsNativeControls)
    }

    private func makeConfiguredWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = false
        return webView
    }
}
#elseif os(macOS)
import AppKit

private struct PlatformYouTubePlayerRepresentable: NSViewRepresentable {
    let bridge: YouTubePlayerBridge
    let videoID: String
    let showsNativeControls: Bool

    func makeCoordinator() -> YouTubePlayerCoordinator {
        YouTubePlayerCoordinator(
            bridge: bridge,
            initialVideoID: videoID,
            showsNativeControls: showsNativeControls
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = makeConfiguredWebView()
        context.coordinator.connect(webView: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.updateVideoID(videoID)
        context.coordinator.updateControls(showsNativeControls)
    }

    private func makeConfiguredWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = false
        return webView
    }
}
#endif
