import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import CoreGraphics
import AVFoundation
import CoreMedia

// MARK: - WebP Converter (uses libwebp C API)

struct WebPConverter {
    /// Converts image data to WebP format via libwebp
    static func convert(imageData: Data, quality: Float) -> Data? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let pixelData = context.data else {
            return nil
        }

        let rgba = pixelData.assumingMemoryBound(to: UInt8.self)

        var output: UnsafeMutablePointer<UInt8>? = nil
        let size = WebPEncodeRGBA(rgba, Int32(width), Int32(height), Int32(bytesPerRow), quality, &output)

        guard size > 0, let outputPtr = output else {
            return nil
        }

        let data = Data(bytes: outputPtr, count: size)
        WebPFree(outputPtr)
        return data
    }
}

// MARK: - Video Output Format

enum VideoOutputFormat: String, CaseIterable {
    case mp4 = "MP4 (H.264)"
    case webm = "WebM (VP9)"

    var fileExtension: String {
        switch self {
        case .mp4: return "mp4"
        case .webm: return "webm"
        }
    }
}

// MARK: - Video Optimizer (uses AVFoundation for MP4, libvpx for WebM)

struct VideoOptimizer {
    struct Settings {
        var maxWidth: Int
        var fps: Int
        var bitrateMbps: Double
        var format: VideoOutputFormat
    }

    /// Optimizes a video file
    static func optimize(inputURL: URL, outputURL: URL, settings: Settings, completion: @escaping (Bool) -> Void) {
        switch settings.format {
        case .mp4:
            optimizeToMP4(inputURL: inputURL, outputURL: outputURL, settings: settings, completion: completion)
        case .webm:
            DispatchQueue.global(qos: .userInitiated).async {
                let success = optimizeToWebM(inputURL: inputURL, outputURL: outputURL, settings: settings)
                DispatchQueue.main.async { completion(success) }
            }
        }
    }

    /// Optimizes video to MP4 using AVFoundation
    private static func optimizeToMP4(inputURL: URL, outputURL: URL, settings: Settings, completion: @escaping (Bool) -> Void) {
        let asset = AVAsset(url: inputURL)

        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            completion(false)
            return
        }

        let naturalSize = videoTrack.naturalSize
        let transform = videoTrack.preferredTransform
        let isPortrait = abs(transform.b) == 1 && abs(transform.c) == 1
        let sourceWidth = isPortrait ? naturalSize.height : naturalSize.width
        let sourceHeight = isPortrait ? naturalSize.width : naturalSize.height

        let scale = min(1.0, CGFloat(settings.maxWidth) / sourceWidth)
        let outputWidth = Int(sourceWidth * scale)
        let outputHeight = Int(sourceHeight * scale)
        let evenWidth = outputWidth % 2 == 0 ? outputWidth : outputWidth - 1
        let evenHeight = outputHeight % 2 == 0 ? outputHeight : outputHeight - 1

        try? FileManager.default.removeItem(at: outputURL)

        guard let reader = try? AVAssetReader(asset: asset),
              let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
            completion(false)
            return
        }

        let readerVideoSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let readerVideoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerVideoSettings)
        readerVideoOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(readerVideoOutput) else { completion(false); return }
        reader.add(readerVideoOutput)

        let bitrateValue = Int(settings.bitrateMbps * 1_000_000)
        let writerVideoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: evenWidth,
            AVVideoHeightKey: evenHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrateValue,
                AVVideoMaxKeyFrameIntervalKey: settings.fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let writerVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: writerVideoSettings)
        writerVideoInput.expectsMediaDataInRealTime = false
        writerVideoInput.transform = videoTrack.preferredTransform

        guard writer.canAdd(writerVideoInput) else { completion(false); return }
        writer.add(writerVideoInput)

        var readerAudioOutput: AVAssetReaderTrackOutput?
        var writerAudioInput: AVAssetWriterInput?

        if let audioTrack = asset.tracks(withMediaType: .audio).first {
            let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            audioOutput.alwaysCopiesSampleData = false
            if reader.canAdd(audioOutput) {
                reader.add(audioOutput)
                readerAudioOutput = audioOutput
                let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
                audioInput.expectsMediaDataInRealTime = false
                if writer.canAdd(audioInput) {
                    writer.add(audioInput)
                    writerAudioInput = audioInput
                }
            }
        }

        let sourceFPS = videoTrack.nominalFrameRate
        let targetFPS = Float(settings.fps)
        let frameSkipInterval = sourceFPS > targetFPS ? Int(round(sourceFPS / targetFPS)) : 1
        let targetFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))

        writer.shouldOptimizeForNetworkUse = true
        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let videoQueue = DispatchQueue(label: "com.mystic.webpify.video")
        let audioQueue = DispatchQueue(label: "com.mystic.webpify.audio")
        let group = DispatchGroup()

        group.enter()
        var frameIndex = 0
        var outputFrameIndex = 0
        writerVideoInput.requestMediaDataWhenReady(on: videoQueue) {
            while writerVideoInput.isReadyForMoreMediaData {
                guard reader.status == .reading else {
                    writerVideoInput.markAsFinished()
                    group.leave()
                    return
                }
                guard let sampleBuffer = readerVideoOutput.copyNextSampleBuffer() else {
                    writerVideoInput.markAsFinished()
                    group.leave()
                    return
                }
                if frameIndex % frameSkipInterval == 0 {
                    let newTime = CMTimeMultiply(targetFrameDuration, multiplier: Int32(outputFrameIndex))
                    if let retrimed = retrimedSampleBuffer(sampleBuffer, newTime: newTime) {
                        writerVideoInput.append(retrimed)
                        outputFrameIndex += 1
                    }
                }
                frameIndex += 1
            }
        }

        if let audioOutput = readerAudioOutput, let audioInput = writerAudioInput {
            group.enter()
            audioInput.requestMediaDataWhenReady(on: audioQueue) {
                while audioInput.isReadyForMoreMediaData {
                    guard reader.status == .reading else {
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                    guard let sampleBuffer = audioOutput.copyNextSampleBuffer() else {
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                    audioInput.append(sampleBuffer)
                }
            }
        }

        group.notify(queue: .main) {
            writer.finishWriting {
                completion(writer.status == .completed)
            }
        }
    }

    /// Optimizes video to WebM using libvpx + custom muxer
    private static func optimizeToWebM(inputURL: URL, outputURL: URL, settings: Settings) -> Bool {
        let asset = AVAsset(url: inputURL)

        guard let videoTrack = asset.tracks(withMediaType: .video).first else { return false }

        let naturalSize = videoTrack.naturalSize
        let transform = videoTrack.preferredTransform
        let isPortrait = abs(transform.b) == 1 && abs(transform.c) == 1
        let sourceWidth = isPortrait ? naturalSize.height : naturalSize.width
        let sourceHeight = isPortrait ? naturalSize.width : naturalSize.height

        let scale = min(1.0, CGFloat(settings.maxWidth) / sourceWidth)
        var outputWidth = Int(sourceWidth * scale)
        var outputHeight = Int(sourceHeight * scale)
        if outputWidth % 2 != 0 { outputWidth -= 1 }
        if outputHeight % 2 != 0 { outputHeight -= 1 }

        try? FileManager.default.removeItem(at: outputURL)

        // Set up AVAssetReader
        guard let reader = try? AVAssetReader(asset: asset) else { return false }

        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: outputWidth,
            kCVPixelBufferHeightKey as String: outputHeight
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerSettings)
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { return false }
        reader.add(readerOutput)
        reader.startReading()

        // Configure VP9 encoder
        var codec: vpx_codec_ctx_t = vpx_codec_ctx_t()
        var cfg: vpx_codec_enc_cfg_t = vpx_codec_enc_cfg_t()

        let iface = vpx_codec_vp9_cx()
        guard vpx_codec_enc_config_default(iface, &cfg, 0) == VPX_CODEC_OK else { return false }

        cfg.g_w = UInt32(outputWidth)
        cfg.g_h = UInt32(outputHeight)
        cfg.g_timebase.num = 1
        cfg.g_timebase.den = Int32(settings.fps)
        cfg.rc_target_bitrate = UInt32(settings.bitrateMbps * 1000) // kbps
        cfg.g_threads = 4
        cfg.g_lag_in_frames = 0
        cfg.rc_end_usage = VPX_VBR
        cfg.kf_max_dist = UInt32(settings.fps * 2)

        guard vpx_codec_enc_init_helper(&codec, iface, &cfg, 0) == VPX_CODEC_OK else {
            return false
        }

        // Speed/quality trade-off (0=slowest/best, 9=fastest)
        vpx_codec_control_set_cpuused(&codec, 4)

        // Create WebM muxer
        guard let muxer = webm_muxer_create(outputURL.path, Int32(outputWidth), Int32(outputHeight), Float(settings.fps)) else {
            vpx_codec_destroy(&codec)
            return false
        }

        let sourceFPS = videoTrack.nominalFrameRate
        let targetFPS = Float(settings.fps)
        let frameSkipInterval = sourceFPS > targetFPS ? max(1, Int(round(sourceFPS / targetFPS))) : 1

        var frameIndex = 0
        var outputFrameIndex: Int64 = 0

        while reader.status == .reading {
            autoreleasepool {
                guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else { return }

                if frameIndex % frameSkipInterval != 0 {
                    frameIndex += 1
                    return
                }

                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    frameIndex += 1
                    return
                }

                CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

                // NV12 (bi-planar) -> I420 (planar) conversion for libvpx
                let yPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!
                let uvPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)!
                let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
                let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

                var img = vpx_image_t()
                vpx_img_wrap(&img, VPX_IMG_FMT_I420, UInt32(outputWidth), UInt32(outputHeight), 1, nil)

                // Allocate I420 planes
                let ySize = outputWidth * outputHeight
                let uvSize = (outputWidth / 2) * (outputHeight / 2)
                let i420Buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: ySize + uvSize * 2)
                defer { i420Buffer.deallocate() }

                let i420Y = i420Buffer
                let i420U = i420Buffer.advanced(by: ySize)
                let i420V = i420Buffer.advanced(by: ySize + uvSize)

                // Copy Y plane
                let ySrc = yPlane.assumingMemoryBound(to: UInt8.self)
                for row in 0..<outputHeight {
                    memcpy(i420Y.advanced(by: row * outputWidth), ySrc.advanced(by: row * yStride), outputWidth)
                }

                // Deinterleave UV (NV12 UVUV -> I420 separate U, V)
                let uvSrc = uvPlane.assumingMemoryBound(to: UInt8.self)
                let uvHeight = outputHeight / 2
                let uvWidth = outputWidth / 2
                for row in 0..<uvHeight {
                    for col in 0..<uvWidth {
                        i420U[row * uvWidth + col] = uvSrc[row * uvStride + col * 2]
                        i420V[row * uvWidth + col] = uvSrc[row * uvStride + col * 2 + 1]
                    }
                }

                img.planes.0 = i420Y
                img.planes.1 = i420U
                img.planes.2 = i420V
                img.stride.0 = Int32(outputWidth)
                img.stride.1 = Int32(uvWidth)
                img.stride.2 = Int32(uvWidth)

                let pts = outputFrameIndex
                let encResult = vpx_codec_encode(&codec, &img, pts, 1, 0, UInt(VPX_DL_GOOD_QUALITY))

                if encResult == VPX_CODEC_OK {
                    var iter: vpx_codec_iter_t? = nil
                    while let pkt = vpx_codec_get_cx_data(&codec, &iter) {
                        if pkt.pointee.kind == VPX_CODEC_CX_FRAME_PKT {
                            let frameData = pkt.pointee.data.frame
                            let isKey = (frameData.flags & UInt32(VPX_FRAME_IS_KEY)) != 0
                            let timestampNs = outputFrameIndex * Int64(1_000_000_000) / Int64(settings.fps)
                            webm_muxer_write_frame(
                                muxer,
                                frameData.buf.assumingMemoryBound(to: UInt8.self),
                                frameData.sz,
                                timestampNs,
                                isKey ? 1 : 0
                            )
                        }
                    }
                }

                outputFrameIndex += 1
                frameIndex += 1
            }
        }

        // Flush encoder
        vpx_codec_encode(&codec, nil, outputFrameIndex, 1, 0, UInt(VPX_DL_GOOD_QUALITY))
        var iter: vpx_codec_iter_t? = nil
        while let pkt = vpx_codec_get_cx_data(&codec, &iter) {
            if pkt.pointee.kind == VPX_CODEC_CX_FRAME_PKT {
                let frameData = pkt.pointee.data.frame
                let isKey = (frameData.flags & UInt32(VPX_FRAME_IS_KEY)) != 0
                let timestampNs = outputFrameIndex * Int64(1_000_000_000) / Int64(settings.fps)
                webm_muxer_write_frame(
                    muxer,
                    frameData.buf.assumingMemoryBound(to: UInt8.self),
                    frameData.sz,
                    timestampNs,
                    isKey ? 1 : 0
                )
            }
        }

        vpx_codec_destroy(&codec)
        webm_muxer_finalize(muxer)

        return true
    }

    /// Creates a new sample buffer with an adjusted presentation timestamp
    private static func retrimedSampleBuffer(_ sampleBuffer: CMSampleBuffer, newTime: CMTime) -> CMSampleBuffer? {
        var timingInfo = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: newTime,
            decodeTimeStamp: .invalid
        )

        var newBuffer: CMSampleBuffer?
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }

        if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescription: formatDescription,
                sampleTiming: &timingInfo,
                sampleBufferOut: &newBuffer
            )
        }

        return newBuffer
    }
}

// MARK: - Brand

enum Brand {
    /// Orange accent color (#d14b28) — matches the marketing site
    static let accent = Color(red: 209.0 / 255.0, green: 75.0 / 255.0, blue: 40.0 / 255.0)
    static let accentSoft = accent.opacity(0.12)
}

// MARK: - Drop Delegate

let imageExtensions = Set(["png", "jpg", "jpeg", "tiff", "tif", "bmp", "gif", "heic", "heif"])
let videoExtensions = Set(["mp4", "mov", "m4v", "avi"])

struct FileDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: ([URL]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let providers = info.itemProviders(for: [.fileURL])
        var urls: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                let ext = url.pathExtension.lowercased()
                if imageExtensions.contains(ext) || videoExtensions.contains(ext) {
                    urls.append(url)
                }
            }
        }

        group.notify(queue: .main) {
            if !urls.isEmpty {
                onDrop(urls)
            }
        }

        return true
    }
}

// MARK: - Conversion Result

struct ConversionResult: Identifiable {
    let id = UUID()
    let filename: String
    let originalSize: Int64
    let convertedSize: Int64
    let saved: Bool
    let message: String
}

// MARK: - Main View

struct ContentView: View {
    // Shared
    @State private var isTargeted = false
    @State private var results: [ConversionResult] = []
    @State private var isConverting = false
    @State private var outputDirectory: URL? = nil
    @State private var showSettings = false
    @ObservedObject private var fileOpener = FileOpenCoordinator.shared

    // Image settings
    @State private var webpQuality: Double = 80

    // Video settings
    @State private var videoMaxWidth: Double = 1920
    @State private var videoFPS: Double = 30
    @State private var videoBitrate: Double = 2.0
    @State private var videoFormat: VideoOutputFormat = .mp4

    var body: some View {
        VStack(spacing: 16) {
            // Brand header
            HStack(spacing: 12) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 44, height: 44)
                }
                VStack(alignment: .leading, spacing: -4) {
                    Text("Drop it.")
                        .font(.system(size: 22, design: .serif))
                        .foregroundColor(.primary)
                    Text("Smoosh it.")
                        .font(.system(size: 22, design: .serif).italic())
                        .foregroundColor(Brand.accent)
                }
                Spacer()
            }

            // Drop zone
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 2, dash: [8])
                    )
                    .foregroundColor(isTargeted ? Brand.accent : .secondary.opacity(0.5))
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(isTargeted ? Brand.accentSoft : Color.clear)
                    )

                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 36))
                        .foregroundColor(isTargeted ? Brand.accent : .secondary)
                    Text("Drop files here")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("PNG · JPEG · TIFF · BMP · GIF · HEIC")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.7))
                    Text("MP4 · MOV · M4V · AVI")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }
            .frame(height: 140)
            .onDrop(of: [.fileURL], delegate: FileDropDelegate(isTargeted: $isTargeted) { urls in
                processFiles(urls: urls)
            })

            // Defaults summary + settings toggle
            VStack(spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Image: WebP \(Int(webpQuality))% quality")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Video: \(videoFormat.rawValue) \(Int(videoMaxWidth))px \(Int(videoFPS))fps \(String(format: "%.1f", videoBitrate))Mbps")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showSettings.toggle()
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.body)
                            .foregroundColor(showSettings ? Brand.accent : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Adjust settings")
                }

                if showSettings {
                    Divider()

                    // Image settings
                    VStack(spacing: 4) {
                        HStack {
                            Text("WebP Quality")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text("\(Int(webpQuality))%")
                                .font(.subheadline.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $webpQuality, in: 1...100, step: 1)
                    }

                    Divider()

                    // Video settings
                    VStack(spacing: 8) {
                        HStack {
                            Text("Format")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Picker("", selection: $videoFormat) {
                                ForEach(VideoOutputFormat.allCases, id: \.self) { format in
                                    Text(format.rawValue).tag(format)
                                }
                            }
                            .frame(width: 160)
                        }
                        VStack(spacing: 4) {
                            HStack {
                                Text("Max Width")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text("\(Int(videoMaxWidth))px")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $videoMaxWidth, in: 640...3840, step: 160)
                        }
                        VStack(spacing: 4) {
                            HStack {
                                Text("Frame Rate")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text("\(Int(videoFPS)) fps")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $videoFPS, in: 15...60, step: 5)
                        }
                        VStack(spacing: 4) {
                            HStack {
                                Text("Bitrate")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text(String(format: "%.1f Mbps", videoBitrate))
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $videoBitrate, in: 0.5...20.0, step: 0.5)
                        }
                    }
                }
            }

            // Output directory picker
            HStack {
                Text("Output:")
                    .font(.subheadline.weight(.medium))
                if let dir = outputDirectory {
                    Text(dir.lastPathComponent)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Same as source")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Choose...") {
                    chooseOutputDirectory()
                }
                .controlSize(.small)
            }

            // Results
            if !results.isEmpty {
                Divider()
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(results) { result in
                            HStack {
                                Image(systemName: result.saved ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundColor(result.saved ? Brand.accent : .red)
                                    .font(.caption)
                                Text(result.filename)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if result.saved {
                                    let reduction = 100.0 - (Double(result.convertedSize) / Double(result.originalSize) * 100.0)
                                    Text(formatBytes(result.convertedSize))
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.secondary)
                                    Text(String(format: "%.0f%%", reduction))
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(reduction > 0 ? .green : .orange)
                                } else if !result.message.isEmpty {
                                    Text(result.message)
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }

            if isConverting {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
        .padding(20)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: fileOpener.pendingURLs) { urls in
            guard !urls.isEmpty else { return }
            processFiles(urls: urls)
            fileOpener.pendingURLs = []
        }
        .onAppear {
            let pending = fileOpener.pendingURLs
            if !pending.isEmpty {
                processFiles(urls: pending)
                fileOpener.pendingURLs = []
            }
        }
    }

    /// Opens a directory picker for output location
    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Output Folder"
        if panel.runModal() == .OK {
            outputDirectory = panel.url
        }
    }

    /// Routes files to the appropriate converter
    func processFiles(urls: [URL]) {
        isConverting = true
        results = []

        let images = urls.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
        let videos = urls.filter { videoExtensions.contains($0.pathExtension.lowercased()) }

        let capturedFormat = videoFormat
        let capturedMaxWidth = videoMaxWidth
        let capturedFPS = videoFPS
        let capturedBitrate = videoBitrate
        let capturedWebpQuality = webpQuality
        let capturedOutputDir = outputDirectory

        DispatchQueue.global(qos: .userInitiated).async {
            var newResults: [ConversionResult] = []

            // Process images
            for url in images {
                autoreleasepool {
                    let filename = url.deletingPathExtension().lastPathComponent + ".webp"
                    let outputDir = capturedOutputDir ?? url.deletingLastPathComponent()
                    let outputURL = outputDir.appendingPathComponent(filename)

                    guard let imageData = try? Data(contentsOf: url) else {
                        newResults.append(ConversionResult(
                            filename: url.lastPathComponent, originalSize: 0,
                            convertedSize: 0, saved: false, message: "Could not read file"
                        ))
                        return
                    }

                    let originalSize = Int64(imageData.count)

                    guard let webpData = WebPConverter.convert(imageData: imageData, quality: Float(capturedWebpQuality)) else {
                        newResults.append(ConversionResult(
                            filename: url.lastPathComponent, originalSize: originalSize,
                            convertedSize: 0, saved: false, message: "Conversion failed"
                        ))
                        return
                    }

                    do {
                        try webpData.write(to: outputURL)
                        newResults.append(ConversionResult(
                            filename: url.lastPathComponent, originalSize: originalSize,
                            convertedSize: Int64(webpData.count), saved: true, message: ""
                        ))
                    } catch {
                        newResults.append(ConversionResult(
                            filename: url.lastPathComponent, originalSize: originalSize,
                            convertedSize: 0, saved: false, message: "Write failed"
                        ))
                    }
                }
            }

            if !newResults.isEmpty {
                DispatchQueue.main.async {
                    results.append(contentsOf: newResults)
                }
            }

            // Process videos
            let videoGroup = DispatchGroup()
            for url in videos {
                videoGroup.enter()

                let suffix = capturedFormat == .webm ? "_optimized.webm" : "_optimized.mp4"
                let filename = url.deletingPathExtension().lastPathComponent + suffix
                let outputDir = capturedOutputDir ?? url.deletingLastPathComponent()
                let outputURL = outputDir.appendingPathComponent(filename)

                let originalSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

                let settings = VideoOptimizer.Settings(
                    maxWidth: Int(capturedMaxWidth),
                    fps: Int(capturedFPS),
                    bitrateMbps: capturedBitrate,
                    format: capturedFormat
                )

                VideoOptimizer.optimize(inputURL: url, outputURL: outputURL, settings: settings) { success in
                    let convertedSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0

                    DispatchQueue.main.async {
                        results.append(ConversionResult(
                            filename: url.lastPathComponent,
                            originalSize: originalSize,
                            convertedSize: convertedSize,
                            saved: success,
                            message: success ? "" : "Video optimization failed"
                        ))
                    }
                    videoGroup.leave()
                }
            }

            videoGroup.wait()

            DispatchQueue.main.async {
                isConverting = false
            }
        }
    }

    /// Formats byte count to human-readable string
    func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - File Open Coordinator

/// Bridges files opened via the dock icon (or `open` command) to the active ContentView
final class FileOpenCoordinator: ObservableObject {
    static let shared = FileOpenCoordinator()
    @Published var pendingURLs: [URL] = []

    func enqueue(_ urls: [URL]) {
        pendingURLs = urls
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Called when the user drops files on the dock icon or invokes `open -a Smoosh ...`
    func application(_ application: NSApplication, open urls: [URL]) {
        FileOpenCoordinator.shared.enqueue(urls)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Re-opens (or focuses) the main window when the dock icon is clicked with no visible windows
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return true
    }
}

// MARK: - App

@main
struct SmooshApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Single-window scene — prevents WindowGroup's default behavior of
        // spawning a new window for every file dropped on the dock icon.
        Window("Smoosh", id: "main") {
            ContentView()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
