import AppKit

/// Reserves room for the player *inside* the Dock: 7 spacer tiles for the player plus a
/// half-width spacer that holds a divider before the stacks / Trash, at the start of the
/// Dock's right-hand section. The Dock then draws its own Liquid Glass under the player
/// and keeps everything centred on screen, as it does for any tile.
///
/// Identification has to survive the Dock rewriting its preferences, which it does from
/// time to time and which drops unknown keys (but keeps a tile's label). So our tiles are
/// recognised by the `dockmedia-slot` marker, by the "DockMedia" label, or, if both are
/// gone, by position: exactly our layout of blank spacers, while we know we've installed
/// one. We never add a second run, and never touch the user's own spacers.
enum DockSlot {
    static let spacers = 7
    private static var layout: [String] { Array(repeating: "spacer-tile", count: spacers) + ["small-spacer-tile"] }
    private static let domain = "com.apple.dock" as CFString
    private static let key = "persistent-others" as CFString
    private static let marker = "dockmedia-slot"
    private static let label = "DockMedia"
    private static let installedFlag = "dockSlotInstalled"

    private static func readOthers() -> [[String: Any]] {
        CFPreferencesAppSynchronize(domain)
        return (CFPreferencesCopyAppValue(key, domain) as? [[String: Any]]) ?? []
    }

    private static func isSpacer(_ t: [String: Any]) -> Bool {
        let type = t["tile-type"] as? String
        return type == "spacer-tile" || type == "small-spacer-tile"
    }

    private static func isMarked(_ t: [String: Any]) -> Bool {
        guard isSpacer(t), let d = t["tile-data"] as? [String: Any] else { return false }
        return d[marker] as? Bool == true || d["file-label"] as? String == label
    }

    private static func isBlank(_ t: [String: Any]) -> Bool {
        guard isSpacer(t) else { return false }
        let l = (t["tile-data"] as? [String: Any])?["file-label"] as? String
        return l == nil || l == ""
    }

    private static var flagged: Bool {
        get { UserDefaults.standard.bool(forKey: installedFlag) }
        set { UserDefaults.standard.set(newValue, forKey: installedFlag) }
    }

    /// The leading tiles are exactly our layout as blank spacers: ours with every mark
    /// stripped (the Dock rewrote its prefs, wiping even the label). Nobody else puts
    /// seven spacers and a small spacer at the very start of the right-hand section.
    private static func hasStrippedLayout(_ others: [[String: Any]]) -> Bool {
        guard others.count >= layout.count else { return false }
        return zip(others.prefix(layout.count), layout).allSatisfy {
            ($0["tile-type"] as? String) == $1 && isBlank($0)
        }
    }

    /// Indices of tiles that are ours.
    private static func ourIndices(_ others: [[String: Any]]) -> [Int] {
        var result = Set(others.indices.filter { isMarked(others[$0]) })
        // A leading run of blank spacers is ours only with evidence: some of our marks survive,
        // or we installed and the exact layout is there. "We installed" alone isn't enough,
        // or a user's own spacer at the start of this section would be taken for a leftover.
        if !result.isEmpty || (flagged && hasStrippedLayout(others)) {
            var i = 0
            while i < others.count && i < layout.count && (isMarked(others[i]) || isBlank(others[i])) {
                result.insert(i); i += 1
            }
        }
        return result.sorted()
    }

    /// Any of our tiles are in the Dock, complete or not.
    static var isPresent: Bool { !ourIndices(readOthers()).isEmpty }

    /// Call once a removal has had time to take effect: forget we installed only when
    /// the Dock really no longer has our tiles (it can write its old layout back over ours).
    static func confirmRemoved() {
        if flagged && ourIndices(readOthers()).isEmpty { flagged = false }
    }

    static var isInstalled: Bool {
        let others = readOthers()
        let ours = ourIndices(others)
        guard ours == Array(0..<layout.count) else { return false }
        return zip(others.prefix(layout.count), layout).allSatisfy { ($0["tile-type"] as? String) == $1 }
    }

    private static func tile(_ type: String) -> [String: Any] {
        ["tile-type": type, "tile-data": ["file-label": label, marker: true]]
    }

    /// Adds (or repairs) the slot. Restarts the Dock only if the layout changed.
    @discardableResult
    static func install() -> Bool {
        if isInstalled { flagged = true; return false }
        var others = readOthers()
        for i in ourIndices(others).reversed() { others.remove(at: i) }
        others.insert(contentsOf: layout.map(tile), at: 0)
        flagged = true
        write(others)
        return true
    }

    /// Removes the slot. Restarts the Dock only if something changed. The installed flag
    /// stays set until `confirmRemoved()` sees the tiles gone, so a removal the Dock
    /// undoes is retried instead of leaving an unrecognisable gap.
    @discardableResult
    static func uninstall() -> Bool {
        var others = readOthers()
        let ours = ourIndices(others)
        guard !ours.isEmpty else { flagged = false; return false }
        for i in ours.reversed() { others.remove(at: i) }
        write(others)
        return true
    }

    private static func write(_ others: [[String: Any]]) {
        CFPreferencesSetAppValue(key, others as CFArray, domain)
        CFPreferencesAppSynchronize(domain)
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock") {
            kill(app.processIdentifier, SIGTERM)
        }
    }
}
