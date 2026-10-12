import CoreGraphics
import Foundation
import GemmaFindCore

// gemmafind-cli — developer tool to validate the embedding runtime and the index.
//
//   gemmafind-cli smoke                       # load model, run text/image/audio sanity checks
//   gemmafind-cli index <folder> [--db path]  # index a folder
//   gemmafind-cli search "<query>" [--db path]

func cosine(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

func ms(_ start: Date) -> String { String(format: "%.1f ms", Date().timeIntervalSince(start) * 1000) }

func argValue(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func smoke() async throws {
    let cpu = CommandLine.arguments.contains("--cpu")
    let embedder = GemmaEmbedder(modelPath: ModelInfo.localURL.path)
    var t = Date()
    try await embedder.load(preferGPU: !cpu)
    print("Loaded model on \(await embedder.backendDescription) in \(ms(t))")

    let docs = [
        "Kyoto travel notes: we visited Kinkaku-ji, Fushimi Inari shrine and walked through the Arashiyama bamboo grove.",
        "Quarterly budget spreadsheet: marketing spend rose 12% while server costs fell after the migration.",
        "To bake sourdough, feed the starter, autolyse the flour, then fold the dough every 30 minutes.",
    ]
    t = Date()
    let docVecs = try await embedder.embedDocuments(docs.map { .document(title: nil, text: $0) })
    print("Embedded \(docs.count) docs in \(ms(t)), dim=\(docVecs.first?.count ?? 0)")

    for q in ["japanese temples trip", "how much did we spend on ads", "bread recipe"] {
        t = Date()
        let qv = try await embedder.embedQuery(q)
        let scores = docVecs.map { cosine(qv, $0) }
        let best = scores.indices.max { scores[$0] < scores[$1] }!
        print(String(format: "  q=%-32@ best=%d  scores=%@  (%@)", q as NSString, best,
                     scores.map { String(format: "%.3f", $0) }.joined(separator: ",") as NSString, ms(t) as NSString))
    }

    // Image sanity check with synthetic images: a red and a blue square.
    func solidJPEG(r: CGFloat, g: CGFloat, b: CGFloat) -> Data {
        let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        return MediaProcessor.jpegData(ctx.makeImage()!)!
    }
    t = Date()
    let imgVecs = try await embedder.embedDocuments([.image(solidJPEG(r: 1, g: 0, b: 0)), .image(solidJPEG(r: 0, g: 0, b: 1))])
    print("Embedded 2 images in \(ms(t))")
    for q in ["a red image", "a blue image"] {
        let qv = try await embedder.embedQuery(q)
        print(String(format: "  q=%-14@ red=%.3f blue=%.3f", q as NSString, cosine(qv, imgVecs[0]), cosine(qv, imgVecs[1])))
    }

    // Audio sanity check: 3 s of a 440 Hz tone vs white noise.
    func wav(_ gen: (Int) -> Double) -> Data {
        let n = 16000 * 3
        let samples = (0..<n).map { Int16(max(-1, min(1, gen($0))) * 12000) }
        return MediaProcessor.wavData(pcm16: samples[...], sampleRate: 16000)
    }
    t = Date()
    let audioVecs = try await embedder.embedDocuments([
        .audio(wav { sin(2 * .pi * 440 * Double($0) / 16000) }),
        .audio(wav { _ in Double.random(in: -1...1) }),
    ])
    print("Embedded 2 audio clips in \(ms(t))")
    for q in ["a pure musical tone beep", "static white noise hiss"] {
        let qv = try await embedder.embedQuery(q)
        print(String(format: "  q=%-26@ tone=%.3f noise=%.3f", q as NSString, cosine(qv, audioVecs[0]), cosine(qv, audioVecs[1])))
    }
}

let command = CommandLine.arguments.dropFirst().first ?? "smoke"
let semaphore = DispatchSemaphore(value: 0)
Task {
    do {
        switch command {
        case "smoke": try await smoke()
        default:
            try await runIndexCommand(command)
        }
    } catch {
        print("Error: \(error)")
        exit(1)
    }
    semaphore.signal()
}
semaphore.wait()
