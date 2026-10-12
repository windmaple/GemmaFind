import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Prepares images, video frames and audio segments in the formats LiteRT-LM expects:
/// encoded JPEG bytes for vision, and WAV (16 kHz mono PCM16) for audio.
public enum MediaProcessor {
    public struct Limits: Sendable {
        public var imageMaxPixel: Int = 896
        public var videoMinFrameInterval: Double = 10
        public var videoMaxFrames: Int = 30
        public var audioSegmentSeconds: Double = 20
        public var audioMaxSegments: Int = 30
        public init() {}
    }

    // MARK: Images

    public static func downsampledJPEG(url: URL, maxPixel: Int) -> Data? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts) else { return nil }
        return downsampledJPEG(source: src, maxPixel: maxPixel)
    }

    static func downsampledJPEG(source: CGImageSource, maxPixel: Int) -> Data? {
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else { return nil }
        return jpegData(cg)
    }

    public static func jpegData(_ image: CGImage, quality: Double = 0.85) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: Video frames

    public static func videoFrames(url: URL, limits: Limits) async -> [(Data, Double)] {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0,
              let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else { return [] }
        let interval = max(limits.videoMinFrameInterval, duration / Double(limits.videoMaxFrames))
        var times: [Double] = []
        var t = min(1.0, duration / 2)
        while t < duration && times.count < limits.videoMaxFrames {
            times.append(t)
            t += interval
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: limits.imageMaxPixel, height: limits.imageMaxPixel)
        let tolerance = CMTime(seconds: min(2, interval / 4), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var frames: [(Data, Double)] = []
        for time in times {
            if Task.isCancelled { break }
            do {
                let (image, actual) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
                if let data = jpegData(image) {
                    frames.append((data, actual.seconds.isFinite ? actual.seconds : time))
                }
            } catch {
                continue
            }
        }
        return frames
    }

    /// Single still for previews / thumbnails.
    public static func videoThumbnail(url: URL, at seconds: Double, maxPixel: Int = 1200) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    // MARK: Audio

    public static let audioSampleRate: Double = 16_000

    /// Decodes the audio track of any AVFoundation-readable file (audio or video) into
    /// fixed-length WAV segments, dropping near-silent ones.
    public static func audioSegments(url: URL, limits: Limits) async -> [(Data, Double, Double)] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let samples = decodePCM16Mono(asset: asset, track: track,
                                      maxSeconds: limits.audioSegmentSeconds * Double(limits.audioMaxSegments))
        guard !samples.isEmpty else { return [] }

        let segLen = Int(limits.audioSegmentSeconds * audioSampleRate)
        var out: [(Data, Double, Double)] = []
        var start = 0
        while start < samples.count && out.count < limits.audioMaxSegments {
            let end = min(samples.count, start + segLen)
            // Skip tiny trailing fragments (< 2 s) unless it's the only audio.
            if end - start < Int(2 * audioSampleRate) && !out.isEmpty { break }
            let slice = samples[start..<end]
            if rms(slice) > 0.004 {
                let wav = wavData(pcm16: slice, sampleRate: Int(audioSampleRate))
                out.append((wav, Double(start) / audioSampleRate, Double(end - start) / audioSampleRate))
            }
            start = end
        }
        return out
    }

    static func decodePCM16Mono(asset: AVAsset, track: AVAssetTrack, maxSeconds: Double) -> [Int16] {
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: maxSeconds, preferredTimescale: 600))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: audioSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        var samples: [Int16] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Int16](repeating: 0, count: length / 2)
            chunk.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            samples.append(contentsOf: chunk)
        }
        return samples
    }

    static func rms(_ samples: ArraySlice<Int16>) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        var i = samples.startIndex
        // Subsample for speed.
        while i < samples.endIndex {
            let v = Double(samples[i]) / 32768.0
            sum += v * v
            i += 8
        }
        return (sum / Double((samples.count + 7) / 8)).squareRoot()
    }

    public static func wavData(pcm16: ArraySlice<Int16>, sampleRate: Int) -> Data {
        let dataBytes = pcm16.count * 2
        var d = Data(capacity: 44 + dataBytes)
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        pcm16.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}
