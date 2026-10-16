import CoreGraphics
import Foundation

enum Anim: String, CaseIterable, Codable {
    case walk, idle, drink, cheer, sleep

    /// How many frames we ask the image model for.
    var frameCount: Int {
        switch self {
        case .walk: 6
        case .idle: 4
        case .drink: 4
        case .cheer: 4
        case .sleep: 3
        }
    }

    var frameDuration: Double {
        switch self {
        case .walk: 0.12
        case .idle: 0.32
        case .drink: 0.34
        case .cheer: 0.16
        case .sleep: 0.7
        }
    }

    /// Character height in this pose relative to standing; used to keep every animation the same scale.
    var heightRatio: CGFloat { self == .sleep ? 0.72 : 1 }
}

/// Animation frames for one character. Every frame shares one cell size with feet on the
/// bottom edge, so swapping between animations never jitters or changes the character's size.
struct SpriteSet {
    private let frames: [Anim: [CGImage]]

    init?(_ frames: [Anim: [CGImage]]) {
        guard let walk = frames[.walk], !walk.isEmpty else { return nil }
        self.frames = frames
    }

    func frames(_ anim: Anim) -> [CGImage] {
        if let f = frames[anim], !f.isEmpty { return f }
        switch anim {
        case .walk: return frames[.walk]!
        case .idle: return [frames[.walk]![0]]
        case .drink: return self.frames(.idle)
        case .cheer: return self.frames(.drink)
        case .sleep: return self.frames(.idle)
        }
    }

    func has(_ anim: Anim) -> Bool { !(frames[anim]?.isEmpty ?? true) }

    func frame(_ anim: Anim, at time: Double) -> CGImage {
        let f = frames(anim)
        let duration = anim == .walk ? 0.75 / Double(f.count) : anim.frameDuration
        return f[Int(time / duration) % f.count]
    }

    var aspect: CGFloat {
        let f = frames(.walk)[0]
        return CGFloat(f.width) / CGFloat(f.height)
    }
}

struct PixelRect {
    var x: Int, y: Int, w: Int, h: Int
}

/// RGBA8 premultiplied bitmap, row 0 = top of the image.
struct Bitmap {
    let w: Int
    let h: Int
    var px: [UInt8]

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    init?(_ cg: CGImage) {
        w = cg.width
        h = cg.height
        px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let (width, height) = (w, h)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4, space: Bitmap.sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        if !ok { return nil }
    }

    @inline(__always) func alpha(_ x: Int, _ y: Int) -> UInt8 { px[(y * w + x) * 4 + 3] }

    static func makeImage(_ bytes: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - Background removal

    /// Image models sometimes ignore "transparent background" and paint a flat color
    /// (or a fake checkerboard). Flood-fill those colors from the edges to make them transparent.
    mutating func removeBackgroundIfNeeded() {
        var border: [Int] = []
        for x in stride(from: 0, to: w, by: 2) { border.append(x); border.append((h - 1) * w + x) }
        for y in stride(from: 0, to: h, by: 2) { border.append(y * w); border.append(y * w + w - 1) }

        let opaque = border.filter { px[$0 * 4 + 3] > 240 }
        guard Double(opaque.count) > Double(border.count) * 0.6 else { return }

        var buckets: [Int: Int] = [:]
        for i in opaque {
            let key = Int(px[i * 4] >> 4) << 8 | Int(px[i * 4 + 1] >> 4) << 4 | Int(px[i * 4 + 2] >> 4)
            buckets[key, default: 0] += 1
        }
        let bgColors: [(Int, Int, Int)] = buckets
            .sorted { $0.value > $1.value }
            .prefix(2)
            .filter { Double($0.value) > Double(border.count) * 0.1 }
            .map { (($0.key >> 8 & 15) * 16 + 8, ($0.key >> 4 & 15) * 16 + 8, ($0.key & 15) * 16 + 8) }
        guard !bgColors.isEmpty else { return }

        func matches(_ i: Int) -> Bool {
            let o = i * 4
            guard px[o + 3] > 0 else { return true }
            let r = Int(px[o]), g = Int(px[o + 1]), b = Int(px[o + 2])
            return bgColors.contains { abs(r - $0.0) <= 28 && abs(g - $0.1) <= 28 && abs(b - $0.2) <= 28 }
        }

        var visited = [Bool](repeating: false, count: w * h)
        var stack = border.filter(matches)
        for i in stack { visited[i] = true }
        while let i = stack.popLast() {
            let o = i * 4
            px[o] = 0; px[o + 1] = 0; px[o + 2] = 0; px[o + 3] = 0
            let x = i % w, y = i / w
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            where nx >= 0 && ny >= 0 && nx < w && ny < h {
                let n = ny * w + nx
                if !visited[n] && matches(n) { visited[n] = true; stack.append(n) }
            }
        }
    }

    /// Drop faint anti-aliasing haze so it doesn't glue frames together.
    mutating func cleanAlpha() {
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] < 48 {
            px[i] = 0; px[i + 1] = 0; px[i + 2] = 0; px[i + 3] = 0
        }
    }

    // MARK: - Segmentation

    static func runs(_ on: [Bool], mergeGap: Int, minLength: Int) -> [Range<Int>] {
        var raw: [Range<Int>] = []
        var start: Int?
        for (i, v) in on.enumerated() {
            if v { if start == nil { start = i } } else if let s = start { raw.append(s..<i); start = nil }
        }
        if let s = start { raw.append(s..<on.count) }

        var merged: [Range<Int>] = []
        for r in raw {
            if let last = merged.last, r.lowerBound - last.upperBound <= mergeGap {
                merged[merged.count - 1] = last.lowerBound..<r.upperBound
            } else {
                merged.append(r)
            }
        }
        return merged.filter { $0.count >= minLength }
    }

    func rowBands() -> [Range<Int>] {
        var on = [Bool](repeating: false, count: h)
        for y in 0..<h {
            var c = 0
            for x in 0..<w where alpha(x, y) > 64 { c += 1; if c >= 2 { break } }
            on[y] = c >= 2
        }
        return Bitmap.runs(on, mergeGap: max(2, h / 150), minLength: max(8, h / 14))
    }

    /// Tight vertical bounds of content within the given columns and band.
    private func tightRect(cols: Range<Int>, band: Range<Int>) -> PixelRect? {
        var top = Int.max, bottom = -1
        for y in band {
            for x in cols where alpha(x, y) > 64 {
                top = min(top, y); bottom = max(bottom, y)
                break
            }
        }
        guard bottom >= top else { return nil }
        return PixelRect(x: cols.lowerBound, y: top, w: cols.count, h: bottom - top + 1)
    }

    func frames(in band: Range<Int>) -> [PixelRect] {
        var on = [Bool](repeating: false, count: w)
        for x in 0..<w {
            for y in band where alpha(x, y) > 64 { on[x] = true; break }
        }
        let segs = Bitmap.runs(on, mergeGap: max(3, band.count / 30), minLength: max(4, band.count / 12))
        var rects = segs.compactMap { tightRect(cols: $0, band: band) }

        // Drop stray fragments (sparkles, droplets) that are much smaller than a typical frame.
        let areas = rects.map { $0.w * $0.h }.sorted()
        if let median = areas.isEmpty ? nil : areas[areas.count / 2] {
            rects = rects.filter { $0.w * $0.h >= median / 4 }
        }

        // Frames drawn touching each other come back as one wide blob: split it evenly.
        if rects.count == 1, let r = rects.first, Double(r.w) > Double(r.h) * 1.6 {
            let n = max(2, Int((Double(r.w) / (Double(r.h) * 0.55)).rounded()))
            let step = r.w / n
            rects = (0..<n).compactMap { i in
                tightRect(cols: (r.x + i * step)..<(r.x + (i + 1) * step), band: band)
            }
        }
        return rects
    }

    func crop(_ r: PixelRect) -> CGImage? {
        var out = [UInt8](repeating: 0, count: r.w * r.h * 4)
        for row in 0..<r.h {
            let src = ((r.y + row) * w + r.x) * 4
            out.replaceSubrange((row * r.w * 4)..<((row + 1) * r.w * 4), with: px[src..<(src + r.w * 4)])
        }
        return Bitmap.makeImage(out, r.w, r.h)
    }
}

enum SpriteSlicer {
    /// Each row of the sheet as tightly cropped frames, top to bottom.
    static func rows(_ cg: CGImage) -> [[CGImage]] {
        guard var bmp = Bitmap(cg) else { return [] }
        bmp.removeBackgroundIfNeeded()
        bmp.cleanAlpha()
        return bmp.rowBands()
            .map { bmp.frames(in: $0).compactMap(bmp.crop) }
            .filter { !$0.isEmpty }
    }

    /// Frames of a single-animation sheet: the row with the most frames.
    static func row(_ cg: CGImage) -> [CGImage] {
        rows(cg).max { $0.count < $1.count } ?? []
    }

    /// Old two-row sheets (row 1: walk, row 2: drinking), e.g. imported by hand.
    static func legacySheet(_ cg: CGImage) -> SpriteSet? {
        let all = rows(cg)
        guard let walkIndex = all.indices.max(by: { all[$0].count < all[$1].count }) else { return nil }
        var crops: [Anim: [CGImage]] = [.walk: all[walkIndex]]
        if let other = all.indices.first(where: { $0 != walkIndex }) { crops[.drink] = all[other] }
        return SpriteAssembler.assemble(crops)
    }
}

/// Puts frames from separately generated sheets onto one shared canvas at one shared scale.
enum SpriteAssembler {
    private static func median(_ v: [Int]) -> CGFloat {
        let s = v.sorted()
        return CGFloat(s[s.count / 2])
    }

    static func assemble(_ crops: [Anim: [CGImage]]) -> SpriteSet? {
        guard let walk = crops[.walk], !walk.isEmpty else { return nil }
        let reference = median(walk.map(\.height))

        var sized: [Anim: [(CGImage, CGSize)]] = [:]
        for (anim, images) in crops where !images.isEmpty {
            let scale = reference * anim.heightRatio / median(images.map(\.height))
            sized[anim] = images.map { ($0, CGSize(width: CGFloat($0.width) * scale, height: CGFloat($0.height) * scale)) }
        }
        let all = sized.values.flatMap { $0 }
        let cellW = Int(ceil(all.map(\.1.width).max()!))
        let cellH = Int(ceil(all.map(\.1.height).max()!))

        var frames: [Anim: [CGImage]] = [:]
        for (anim, items) in sized {
            frames[anim] = items.compactMap { image, size in
                guard let ctx = CGContext(data: nil, width: cellW, height: cellH, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: Bitmap.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return nil }
                ctx.interpolationQuality = .high
                // CG origin is bottom-left, so y = 0 puts the feet on the cell's bottom edge.
                ctx.draw(image, in: CGRect(x: (CGFloat(cellW) - size.width) / 2, y: 0, width: size.width, height: size.height))
                return ctx.makeImage()
            }
        }
        return SpriteSet(frames)
    }

    /// Lays frames side by side, so a reviewer (Claude) sees exactly what will be animated.
    static func strip(_ images: [CGImage], height: Int = 220) -> CGImage? {
        guard !images.isEmpty else { return nil }
        let gap = 16
        let widths = images.map { Int(CGFloat($0.width) * CGFloat(height) / CGFloat($0.height)) }
        let total = widths.reduce(0, +) + gap * (images.count + 1)
        guard let ctx = CGContext(data: nil, width: total, height: height + gap * 2, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: Bitmap.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: total, height: height + gap * 2))
        var x = gap
        for (image, w) in zip(images, widths) {
            ctx.draw(image, in: CGRect(x: x, y: gap, width: w, height: height))
            x += w + gap
        }
        return ctx.makeImage()
    }
}
