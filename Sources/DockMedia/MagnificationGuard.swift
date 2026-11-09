import AppKit

/// Keeps the Dock from magnifying around the player, like a widget rather than an icon:
/// as the pointer approaches our slot, the Dock's magnified size is eased down to the
/// tile size (live, via CoreDock, no Dock restart), and eased back up as it leaves.
///
/// The user's own setting is saved before any change and restored on exit, or on the
/// next launch if DockMedia didn't exit cleanly.
final class MagnificationGuard {
    private typealias GetF = @convention(c) () -> Float
    private typealias SetF = @convention(c) (Float) -> Void
    private typealias GetB = @convention(c) () -> Bool

    private let getMag: GetF?
    private let setMag: SetF?
    private let getTile: GetF?
    private let isEnabled: GetB?
    private let savedKey = "savedMagnificationSize"

    /// The user's magnified size (CoreDock units: points = 16 + f·112) while we're adjusting it.
    private var original: Float?
    private var current: Float?

    init() {
        let h = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW)
        func sym<T>(_ n: String, _ t: T.Type) -> T? { h.flatMap { dlsym($0, n) }.map { unsafeBitCast($0, to: t) } }
        getMag = sym("CoreDockGetMagnificationSize", GetF.self)
        setMag = sym("CoreDockSetMagnificationSize", SetF.self)
        getTile = sym("CoreDockGetTileSize", GetF.self)
        isEnabled = sym("CoreDockIsMagnificationEnabled", GetB.self)
        // Recover from an unclean exit.
        if let saved = UserDefaults.standard.object(forKey: savedKey) as? Float {
            original = saved
            restore()
        }
    }

    /// `distance`: horizontal distance (pt) from the pointer to the player, 0 when over it;
    /// nil when the pointer isn't on the Dock at all.
    func update(distance: CGFloat?, pitch: CGFloat) {
        guard let getMag, let setMag, let getTile, isEnabled?() == true else { return }
        guard let distance else { restore(); return }

        if original == nil {
            let o = getMag()
            original = o
            UserDefaults.standard.set(o, forKey: savedKey)
        }
        guard let original else { return }
        let tile = getTile()
        guard original > tile else { return }

        // Full magnification two tiles away, none over the player; smoothstep between.
        let span = pitch * 2
        let t = Float(min(max(distance / span, 0), 1))
        let eased = t * t * (3 - 2 * t)
        let target = tile + (original - tile) * eased
        if current == nil || abs(target - current!) > 0.003 || (target == tile && current != tile) || (target == original && current != original) {
            setMag(target)
            current = target
        }
    }

    /// Puts the user's magnified size back (live and in the Dock's preferences).
    func restore() {
        guard let original else { return }
        if current != original, let setMag { setMag(original) }
        let points = Double(16 + original * 112).rounded()
        CFPreferencesSetAppValue("largesize" as CFString, points as CFNumber, "com.apple.dock" as CFString)
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        self.original = nil
        current = nil
        UserDefaults.standard.removeObject(forKey: savedKey)
    }
}
