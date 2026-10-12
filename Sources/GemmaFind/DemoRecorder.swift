import AppKit
import GemmaFindCore

/// Scripted demo recorder (test mode only): types queries into the real panel, renders each
/// frame offscreen onto a backdrop with a caption, and writes numbered PNGs plus a
/// `frames.txt` ffmpeg concat list with per-frame durations.
///
///   GEMMAFIND_TEST_FOLDER=… GEMMAFIND_RECORD_DEMO=/out/dir GemmaFind.app/Contents/MacOS/GemmaFind
@MainActor
final class DemoRecorder {
    struct Scene {
        let query: String
        let caption: String
        let hold: Double
        var selectNext: Int = 0
    }

    let outDir: URL
    private var frameIndex = 0
    private var concat = "ffconcat version 1.0\n"
    private var lastFile: String?

    static let canvas = NSSize(width: 1180, height: 760)

    init(outDir: URL) { self.outDir = outDir }

    func run(model: AppModel) async {
        try? FileManager.default.removeItem(at: outDir)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let panel = SearchPanelController.shared
        // Let the initial index settle (max ~20 s).
        for _ in 0..<200 {
            if model.progress.phase == .idle, model.progress.indexedFiles > 0 { break }
            await sleep(0.1)
        }

        // 1. Shortcut intro (panel hidden).
        frame(panel: nil, caption: "Press  ⌃ Space  anywhere", keycaps: true, duration: 1.6)
        // 2. Panel opens.
        panel.show()
        await sleep(0.8)
        frame(panel: panel, caption: "GemmaFind — search your Mac by meaning", duration: 1.6)

        let scenes = [
            Scene(query: "what to bring on a hike", caption: "Understands intent — best-matching sentences highlighted", hold: 2.8),
            Scene(query: "rent and pets clause", caption: "Inside Word, PDF, RTF and HTML documents", hold: 2.6),
            Scene(query: "eiffel tower", caption: "Photos too — EmbeddingGemma 2 is multimodal", hold: 2.4),
            Scene(query: "cache eviction", caption: "Code: jumps straight to the relevant lines", hold: 2.6),
        ]
        for scene in scenes {
            model.query = ""
            await sleep(0.15)
            frame(panel: panel, caption: scene.caption, duration: 0.35)
            var typed = ""
            for ch in scene.query {
                typed.append(ch)
                model.query = typed
                await sleep(0.03)
                frame(panel: panel, caption: scene.caption, duration: 0.07)
            }
            // Wait for results + on-the-fly sentence highlighting.
            await sleep(1.6)
            frame(panel: panel, caption: scene.caption, duration: scene.hold)
        }
        frame(panel: panel, caption: "100% on-device · EmbeddingGemma 2 on LiteRT-LM (Metal GPU)", duration: 2.6)

        // ffmpeg's concat demuxer needs the last file repeated to honor its duration.
        if let last = lastFile { concat += "file '\(last)'\n" }
        try? concat.write(to: outDir.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
        NSLog("GemmaFind demo recording: wrote \(frameIndex) frames to \(outDir.path)")
    }

    private func sleep(_ s: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
    }

    // MARK: Rendering

    private func frame(panel: SearchPanelController?, caption: String, keycaps: Bool = false, duration: Double) {
        let size = Self.canvas
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        // Backdrop gradient.
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.20, green: 0.24, blue: 0.62, alpha: 1),
            NSColor(calibratedRed: 0.47, green: 0.27, blue: 0.70, alpha: 1),
            NSColor(calibratedRed: 0.86, green: 0.40, blue: 0.55, alpha: 1),
        ])
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: -35)

        let panelRect = NSRect(x: (size.width - 960) / 2, y: 120, width: 960, height: 597)
        if let panel, let image = panel.renderImage() {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 30
            shadow.shadowOffset = NSSize(width: 0, height: -10)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: panelRect.insetBy(dx: 2, dy: 2), xRadius: 18, yRadius: 18).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: panelRect, xRadius: 18, yRadius: 18).addClip()
            image.draw(in: panelRect)
            NSGraphicsContext.restoreGraphicsState()
        }

        if keycaps { drawKeycaps(center: NSPoint(x: size.width / 2, y: size.height / 2 + 30)) }

        // Caption pill.
        let font = NSFont.systemFont(ofSize: 24, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let text = NSAttributedString(string: caption, attributes: attrs)
        let ts = text.size()
        let pill = NSRect(x: (size.width - ts.width) / 2 - 22, y: 44, width: ts.width + 44, height: ts.height + 18)
        NSColor.black.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        text.draw(at: NSPoint(x: pill.minX + 22, y: pill.minY + 9))

        NSGraphicsContext.restoreGraphicsState()

        frameIndex += 1
        let name = String(format: "frame-%04d.png", frameIndex)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: outDir.appendingPathComponent(name))
            concat += "file '\(name)'\nduration \(String(format: "%.3f", duration))\n"
            lastFile = name
        }
    }

    private func drawKeycaps(center: NSPoint) {
        let keys = ["⌃ control", "space"]
        let widths: [CGFloat] = [190, 320]
        let height: CGFloat = 96, gap: CGFloat = 28
        var x = center.x - (widths.reduce(0, +) + gap) / 2
        for (key, w) in zip(keys, widths) {
            let r = NSRect(x: x, y: center.y - height / 2, width: w, height: height)
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 14
            shadow.shadowOffset = NSSize(width: 0, height: -6)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            NSColor(white: 0.97, alpha: 1).setFill()
            NSBezierPath(roundedRect: r, xRadius: 16, yRadius: 16).fill()
            NSGraphicsContext.restoreGraphicsState()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30, weight: .medium),
                                                        .foregroundColor: NSColor(white: 0.25, alpha: 1)]
            let t = NSAttributedString(string: key, attributes: attrs)
            let ts = t.size()
            t.draw(at: NSPoint(x: r.midX - ts.width / 2, y: r.midY - ts.height / 2))
            x += w + gap
        }
    }
}
