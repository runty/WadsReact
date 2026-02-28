import Foundation

#if canImport(Libavcodec) && canImport(Libavformat) && canImport(Libavutil)
import Libavcodec
import Libavformat
import Libavutil

private final class FFmpegInterruptState {
    private(set) var startTime = CFAbsoluteTimeGetCurrent()
    private(set) var lastProgressTime = CFAbsoluteTimeGetCurrent()
    let stallTimeoutSeconds: Double
    let hardTimeoutSeconds: Double

    init(stallTimeoutSeconds: Double, hardTimeoutSeconds: Double) {
        self.stallTimeoutSeconds = stallTimeoutSeconds
        self.hardTimeoutSeconds = hardTimeoutSeconds
    }

    func noteProgress() {
        lastProgressTime = CFAbsoluteTimeGetCurrent()
    }

    func shouldInterrupt() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        return (now - lastProgressTime) > stallTimeoutSeconds || (now - startTime) > hardTimeoutSeconds
    }
}

enum FFmpegRemuxer {
    nonisolated static var isEmbeddedAvailable: Bool { true }

    nonisolated static func remuxMKVToMP4(inputURL: URL, outputURL: URL) throws {
        try remux(inputPath: inputURL.path, outputPath: outputURL.path)
    }

    nonisolated static func remuxMKVToMP4VideoOnly(inputURL: URL, outputURL: URL) throws {
        try remux(inputPath: inputURL.path, outputPath: outputURL.path, includeAudio: false)
    }

    nonisolated private static func remux(inputPath: String, outputPath: String) throws {
        do {
            try remux(inputPath: inputPath, outputPath: outputPath, includeAudio: true)
        } catch {
            // Many MKV files carry audio streams that are valid in MKV but not in MP4.
            // Retry as video-only instead of failing the whole import.
            try? FileManager.default.removeItem(atPath: outputPath)
            try remux(inputPath: inputPath, outputPath: outputPath, includeAudio: false)
        }
    }

    nonisolated private static func remux(inputPath: String, outputPath: String, includeAudio: Bool) throws {
        av_log_set_level(AV_LOG_ERROR)

        let interruptState = Unmanaged.passRetained(
            FFmpegInterruptState(stallTimeoutSeconds: 20, hardTimeoutSeconds: 240)
        )
        defer { interruptState.release() }
        let interruptCallback = makeInterruptCallback(opaque: interruptState.toOpaque())

        var inputContext: UnsafeMutablePointer<AVFormatContext>?
        try checkFFmpegResult(
            avformat_open_input(&inputContext, inputPath, nil, nil),
            message: "Failed to open MKV input."
        )
        guard inputContext != nil else {
            throw FFmpegRemuxerError.failed("Failed to allocate MKV input context.")
        }
        defer {
            avformat_close_input(&inputContext)
        }
        let inputContextValue = inputContext!
        inputContextValue.pointee.interrupt_callback = interruptCallback

        try checkFFmpegResult(
            avformat_find_stream_info(inputContextValue, nil),
            message: "Failed to read MKV stream metadata."
        )
        interruptState.takeUnretainedValue().noteProgress()

        var outputContext: UnsafeMutablePointer<AVFormatContext>?
        try checkFFmpegResult(
            avformat_alloc_output_context2(&outputContext, nil, nil, outputPath),
            message: "Failed to create MP4 output context."
        )
        guard let outputContext else {
            throw FFmpegRemuxerError.failed("Failed to allocate MP4 output context.")
        }

        defer {
            if (outputContext.pointee.oformat.pointee.flags & AVFMT_NOFILE) == 0 {
                avio_closep(&outputContext.pointee.pb)
            }
            avformat_free_context(outputContext)
        }
        outputContext.pointee.interrupt_callback = interruptCallback

        let inputStreamCount = Int(inputContextValue.pointee.nb_streams)
        var primaryVideoStreamIndex: Int?
        var primaryAudioStreamIndex: Int?

        for index in 0..<inputStreamCount {
            guard let inputStream = inputContextValue.pointee.streams[index],
                  let inputCodecParameters = inputStream.pointee.codecpar else {
                continue
            }

            let mediaType = inputCodecParameters.pointee.codec_type

            if mediaType == AVMEDIA_TYPE_VIDEO,
               primaryVideoStreamIndex == nil,
               isMP4CompatibleVideoCodec(inputCodecParameters.pointee.codec_id) {
                primaryVideoStreamIndex = index
                continue
            }

            if mediaType == AVMEDIA_TYPE_AUDIO,
               includeAudio,
               primaryAudioStreamIndex == nil,
               isMP4CompatibleAudioCodec(inputCodecParameters.pointee.codec_id) {
                primaryAudioStreamIndex = index
            }
        }

        var selectedInputIndices: [Int] = []
        if let primaryVideoStreamIndex {
            selectedInputIndices.append(primaryVideoStreamIndex)
        }
        if let primaryAudioStreamIndex {
            selectedInputIndices.append(primaryAudioStreamIndex)
        }

        var streamMap = Array(repeating: Int32(-1), count: inputStreamCount)
        var outputStreamIndex: Int32 = 0

        for index in selectedInputIndices {
            guard let inputStream = inputContextValue.pointee.streams[index],
                  let inputCodecParameters = inputStream.pointee.codecpar else {
                continue
            }

            guard let outputStream = avformat_new_stream(outputContext, nil) else {
                throw FFmpegRemuxerError.failed("Failed to create output stream.")
            }

            try checkFFmpegResult(
                avcodec_parameters_copy(outputStream.pointee.codecpar, inputCodecParameters),
                message: "Failed to copy codec parameters."
            )

            outputStream.pointee.codecpar.pointee.codec_tag = 0
            outputStream.pointee.time_base = inputStream.pointee.time_base
            streamMap[index] = outputStreamIndex
            outputStreamIndex += 1
        }

        guard outputStreamIndex > 0 else {
            if includeAudio {
                throw FFmpegRemuxerError.failed("No MP4-compatible audio/video streams found in MKV.")
            }
            throw FFmpegRemuxerError.failed("No MP4-compatible video stream found in MKV.")
        }

        if (outputContext.pointee.oformat.pointee.flags & AVFMT_NOFILE) == 0 {
            var ioContext: UnsafeMutablePointer<AVIOContext>?
            try checkFFmpegResult(
                avio_open(&ioContext, outputPath, AVIO_FLAG_WRITE),
                message: "Failed to open MP4 output file."
            )
            outputContext.pointee.pb = ioContext
        }

        try checkFFmpegResult(
            avformat_write_header(outputContext, nil),
            message: "Failed to write MP4 header."
        )

        let mappedStreamCount = Int(outputStreamIndex)
        var firstTimestamp = Array(repeating: Int64(0), count: mappedStreamCount)
        var didCaptureFirstTimestamp = Array(repeating: false, count: mappedStreamCount)
        var lastDTS = Array(repeating: Int64.min, count: mappedStreamCount)
        var lastPTS = Array(repeating: Int64.min, count: mappedStreamCount)

        var packet = AVPacket()
        while true {
            let readResult = av_read_frame(inputContextValue, &packet)
            if readResult < 0 {
                if let ioContext = inputContextValue.pointee.pb, avio_feof(ioContext) != 0 {
                    break
                }
                try checkFFmpegResult(readResult, message: "Failed reading MKV packet.")
            }

            defer { av_packet_unref(&packet) }
            interruptState.takeUnretainedValue().noteProgress()

            let inputIndex = Int(packet.stream_index)
            guard inputIndex >= 0, inputIndex < streamMap.count else { continue }

            let mappedIndex = streamMap[inputIndex]
            guard mappedIndex >= 0 else { continue }

            guard let inputStream = inputContextValue.pointee.streams[inputIndex],
                  let outputStream = outputContext.pointee.streams[Int(mappedIndex)] else {
                continue
            }

            packet.stream_index = mappedIndex

            av_packet_rescale_ts(&packet, inputStream.pointee.time_base, outputStream.pointee.time_base)

            let outputIndex = Int(mappedIndex)
            normalizePacketTimestamps(
                &packet,
                outputIndex: outputIndex,
                firstTimestamp: &firstTimestamp,
                didCaptureFirstTimestamp: &didCaptureFirstTimestamp,
                lastDTS: &lastDTS,
                lastPTS: &lastPTS
            )

            if packet.duration < 0 {
                packet.duration = 0
            }
            packet.pos = -1

            try checkFFmpegResult(
                av_interleaved_write_frame(outputContext, &packet),
                message: "Failed writing MP4 packet."
            )
            interruptState.takeUnretainedValue().noteProgress()
        }

        try checkFFmpegResult(
            av_write_trailer(outputContext),
            message: "Failed to finalize MP4 file."
        )
    }

    nonisolated private static func isMP4CompatibleAudioCodec(_ codecID: AVCodecID) -> Bool {
        switch codecID {
        case AV_CODEC_ID_AAC,
             AV_CODEC_ID_ALAC,
             AV_CODEC_ID_MP3:
            return true
        default:
            return false
        }
    }

    nonisolated private static func isMP4CompatibleVideoCodec(_ codecID: AVCodecID) -> Bool {
        switch codecID {
        case AV_CODEC_ID_H264,
             AV_CODEC_ID_HEVC:
            return true
        default:
            return false
        }
    }

    nonisolated private static func makeInterruptCallback(opaque: UnsafeMutableRawPointer) -> AVIOInterruptCB {
        var callback = AVIOInterruptCB()
        callback.callback = { rawPointer in
            guard let rawPointer else {
                return 0
            }
            let state = Unmanaged<FFmpegInterruptState>.fromOpaque(rawPointer).takeUnretainedValue()
            return state.shouldInterrupt() ? 1 : 0
        }
        callback.opaque = opaque
        return callback
    }

    nonisolated private static func normalizePacketTimestamps(
        _ packet: inout AVPacket,
        outputIndex: Int,
        firstTimestamp: inout [Int64],
        didCaptureFirstTimestamp: inout [Bool],
        lastDTS: inout [Int64],
        lastPTS: inout [Int64]
    ) {
        let noPTS = Int64.min
        var pts = packet.pts
        var dts = packet.dts

        if !didCaptureFirstTimestamp[outputIndex] {
            let seed: Int64
            if dts != noPTS {
                seed = dts
            } else if pts != noPTS {
                seed = pts
            } else {
                seed = 0
            }
            firstTimestamp[outputIndex] = seed
            didCaptureFirstTimestamp[outputIndex] = true
        }

        let start = firstTimestamp[outputIndex]
        if dts != noPTS {
            dts -= start
            if dts < 0 { dts = 0 }
        }
        if pts != noPTS {
            pts -= start
            if pts < 0 { pts = 0 }
        }

        if dts != noPTS {
            let previousDTS = lastDTS[outputIndex]
            if previousDTS != Int64.min && dts <= previousDTS {
                dts = previousDTS + 1
            }
            lastDTS[outputIndex] = dts
        }

        if pts != noPTS {
            if dts != noPTS && pts < dts {
                pts = dts
            }
            let previousPTS = lastPTS[outputIndex]
            if previousPTS != Int64.min && pts <= previousPTS {
                pts = previousPTS + 1
                if dts != noPTS && pts < dts {
                    pts = dts
                }
            }
            lastPTS[outputIndex] = pts
        }

        packet.dts = dts
        packet.pts = pts
    }

    nonisolated private static func checkFFmpegResult(_ result: Int32, message: String) throws {
        guard result >= 0 else {
            throw FFmpegRemuxerError.failed("\(message) \(ffmpegErrorString(result))")
        }
    }

    nonisolated private static func ffmpegErrorString(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 512)
        av_strerror(code, &buffer, buffer.count)
        return String(cString: buffer)
    }
}

enum FFmpegRemuxerError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}
#else
enum FFmpegRemuxer {
    nonisolated static var isEmbeddedAvailable: Bool { false }

    nonisolated static func remuxMKVToMP4(inputURL: URL, outputURL: URL) throws {
        throw FFmpegRemuxerError.failed("Embedded FFmpeg libraries are not linked in this build.")
    }
}

enum FFmpegRemuxerError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}
#endif
