import AppKit
import ScreenCaptureKit

/// Liquid Glass takes its tone from what's behind it, not from the system appearance:
/// the Dock over a dark window is dark even in Light mode. So pick the player's text
/// colour like the glass does: sample the brightness of a content-free strip of our slot
/// (above the artwork). Needs Screen Recording; without it, follow the system appearance.
@MainActor
final class GlassSampler {
    private(set) var isDark: Bool?
    private var inFlight = false
    private var lastSample = Date.distantPast
    var onChange: ((Bool?) -> Void)?

    /// `slotCG`: our slot in CG global coords (top-left origin).
    func sampleIfNeeded(slotCG: CGRect, force: Bool = false) {
        let now = Date()
        guard !inFlight, force || now.timeIntervalSince(lastSample) > 1.0 else { return }
        guard CGPreflightScreenCaptureAccess() else {
            if isDark != nil { isDark = nil; onChange?(nil) }
            return
        }
        lastSample = now
        inFlight = true
        // 4pt strip starting 3pt below the platter top: glass only, no player content.
        let strip = CGRect(x: slotCG.minX + 8, y: slotCG.minY + 3, width: max(1, slotCG.width - 16), height: 4)
        Task { @MainActor in
            defer { self.inFlight = false }
            guard let img = try? await SCScreenshotManager.captureImage(in: strip),
                  let lum = Self.meanLuminance(img) else { return }
            // Hysteresis so it doesn't flicker on mid-grey glass.
            let dark: Bool
            if let cur = self.isDark { dark = cur ? lum < 0.56 : lum < 0.44 } else { dark = lum < 0.5 }
            if dark != self.isDark { self.isDark = dark; self.onChange?(dark) }
        }
    }

    private static func meanLuminance(_ img: CGImage) -> Double? {
        let w = 32, h = 2
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            sum += 0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])
        }
        return sum / Double(w * h) / 255
    }
}
