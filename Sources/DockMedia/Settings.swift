import AppKit
import Observation
import ServiceManagement

@Observable
final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    var showMenuBarIcon: Bool {
        didSet { d.set(showMenuBarIcon, forKey: "showMenuBarIcon") }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { NSLog("DockMedia: launch at login: \(error)") }
        }
    }

    private init() {
        showMenuBarIcon = d.object(forKey: "showMenuBarIcon") as? Bool ?? false
    }

    /// Open at Login is on by default. Applied once, so turning it off later sticks, and
    /// only from /Applications, so a copy run from elsewhere doesn't become the login item.
    func applyLoginDefault() {
        let key = "didApplyLoginDefault"
        guard !d.bool(forKey: key), Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        launchAtLogin = true
        d.set(true, forKey: key)
    }
}

/// Geometry derived from the live Dock, so the player reads as Dock content:
/// the artwork is exactly an icon in the first slot, everything else is on the
/// same baseline grid. Measured on macOS 26/27 at tile size 41: slot pitch 43pt,
/// platter 55pt, visible icon squircle 33pt, centred vertically.
struct Metrics: Equatable {
    /// Resting slot pitch (one tile, including padding).
    var pitch: CGFloat = 43
    /// Platter height.
    var platter: CGFloat = 55

    /// The player itself (7 tiles) and the half-tile that holds the divider.
    var playerWidth: CGFloat { pitch * CGFloat(DockSlot.spacers) }
    var dividerWidth: CGFloat { pitch / 2 }
    var width: CGFloat { playerWidth + dividerWidth }
    /// The Dock's divider: 1pt, as tall as an icon tile.
    var dividerHeight: CGFloat { pitch - 2 }
    /// The visible icon body (Dock icons draw ~80% of the tile; the rest is padding).
    var icon: CGFloat { (pitch * 0.77).rounded() }
    /// Left inset so the artwork sits where an icon in the first slot would.
    var inset: CGFloat { ((pitch - icon) / 2).rounded() }
    var artRadius: CGFloat { icon * 0.225 }
    var artGap: CGFloat { (pitch * 0.23).rounded() }

    var titleSize: CGFloat { (pitch * 0.29 * 2).rounded() / 2 }      // 12.5
    var subtitleSize: CGFloat { (pitch * 0.256 * 2).rounded() / 2 }  // 11
    var timeSize: CGFloat { (pitch * 0.23 * 2).rounded() / 2 }       // 10
    var barHeight: CGFloat { max(3, (pitch * 0.07).rounded()) }        // 3

    var button: CGFloat { (pitch * 0.65).rounded() }                    // 28
    var playGlyph: CGFloat { (pitch * 0.4).rounded() }                  // 17
    var skipGlyph: CGFloat { (pitch * 0.32).rounded() }                 // 14
}

@Observable
final class PanelUIState {
    var revealed = false
    /// Whether there's media to show (content fades in/out on this).
    var showing = false
    /// Tone of the Dock glass behind us (nil = follow the system appearance).
    var glassDark: Bool?
    var metrics = Metrics()
    /// Mouse location in the panel's SwiftUI coordinate space (top-left origin), nil when outside.
    var mouse: CGPoint?
    var scrubbing = false
    /// Bumped when the track changes; used to restart title scrolling.
    var trackChangeDate = Date()
}
