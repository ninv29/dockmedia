import AppKit
import Observation

@Observable
final class NowPlayingModel {
    var hasMedia = false
    var title = ""
    var artist = ""
    var album = ""
    var duration: Double = 0
    var isPlaying = false
    var artwork: NSImage?
    var artworkId: String?
    var explicit: Bool = false
    var bundleId: String?
    var appName: String?
    /// Identity of the current track, for transitions.
    var trackID: String { "\(title)|\(artist)" }

    // Timing: elapsed was `elapsedAtTimestamp` at `timestamp`; advances at `rate` while playing.
    private(set) var elapsedAtTimestamp: Double = 0
    private(set) var timestamp = Date()
    private var rate: Double = 1

    /// When a user action is in flight, briefly ignore contradicting helper updates.
    private var optimisticPlayingUntil: Date?
    private var optimisticSeekUntil: Date?

    @ObservationIgnored let bridge = MediaBridge()
    @ObservationIgnored let explicitResolver = ExplicitResolver()
    @ObservationIgnored private var artworkCache: [String: NSImage] = [:]
    @ObservationIgnored private var trackKey = ""

    init() {
        bridge.onState = { [weak self] in self?.apply($0) }
        bridge.onArtwork = { [weak self] id, data in
            guard let self, let img = NSImage(data: data) else { return }
            self.artworkCache[id] = img
            if self.artworkCache.count > 4 { self.artworkCache = self.artworkCache.filter { $0.key == id || $0.key == self.artworkId } }
            if self.artworkId == id && self.displayedArtId != id {
                self.artworkTimeout?.cancel()
                self.artwork = img
                self.displayedArtId = id
            }
        }
        bridge.onPrevious = { [weak self] action, pos in self?.previousHandled(action: action, position: pos) }
        bridge.start()
    }

    func position(at date: Date) -> Double {
        var p = elapsedAtTimestamp
        if isPlaying { p += date.timeIntervalSince(timestamp) * (rate > 0 ? rate : 1) }
        if duration > 0 { p = min(p, duration) }
        return max(0, p)
    }

    /// True once the helper has reported at least once (so "nothing playing" is real).
    var didReceiveState = false
    /// When playback last stopped being active (nil while playing).
    var pausedSince: Date?

    @ObservationIgnored private var reportedElapsed: Double?
    @ObservationIgnored private var reportedTimestamp: Double?
    @ObservationIgnored private var reportedPlaying = false
    @ObservationIgnored private var artworkTimeout: DispatchWorkItem?
    @ObservationIgnored private var displayedArtId: String?

    // MARK: Momentary gaps

    /// When the player last stopped publishing anything.
    @ObservationIgnored private(set) var infoLostAt: Date?
    /// The process that published the last real info.
    @ObservationIgnored private var sourcePid: pid_t = 0
    /// How long a gap may last while the player is still running. Spotify publishes nothing
    /// for ~0.6s when an album wraps around to its first track, and players do similar
    /// things between items; iOS keeps Now Playing up through all of it.
    static let gapHold: TimeInterval = 2.5

    private var sourceAlive: Bool { sourcePid > 0 && kill(sourcePid, 0) == 0 }

    /// No info right now, but only for a moment: the player's still running and published
    /// recently. The last track keeps showing and the controls keep working. (If the
    /// player quit, this is false at once, so the player leaves without delay.)
    func inInfoGap(at now: Date = Date()) -> Bool {
        guard !hasMedia, let lost = infoLostAt else { return false }
        return now.timeIntervalSince(lost) < Self.gapHold && sourceAlive
    }

    /// There's a player to send commands to.
    var canControl: Bool { hasMedia || inInfoGap() }

    private func apply(_ s: [String: Any]) {
        didReceiveState = true
        let has = (s["hasInfo"] as? Bool) ?? false
        let title = s["title"] as? String ?? ""
        guard has, !title.isEmpty else {
            if hasMedia { hasMedia = false; infoLostAt = Date() }
            reportedPlaying = false
            return
        }
        infoLostAt = nil
        if let pid = s["pid"] as? Int, pid > 0 { sourcePid = pid_t(pid) }

        let bundle = (s["parentBundle"] as? String) ?? (s["bundle"] as? String)
        if bundle != bundleId {
            bundleId = bundle
            appName = bundle.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        }

        let artist = s["artist"] as? String ?? ""
        let album = s["album"] as? String ?? ""
        let key = "\(bundle ?? "")|\(title)|\(artist)|\(album)"
        let trackChanged = key != trackKey

        if self.title != title { self.title = title }
        if self.artist != artist { self.artist = artist }
        if self.album != album { self.album = album }
        if let d = s["duration"] as? Double, d != duration { duration = d } else if trackChanged && s["duration"] == nil { duration = 0 }
        if !hasMedia { hasMedia = true }

        let now = Date()
        let playing = (s["playing"] as? Bool) ?? false

        // Timing. MediaRemote's pause message often repeats the elapsed/timestamp pair from
        // when playback started, so taking it literally jumps the bar back. If the pair is
        // unchanged, the player didn't give us a new position: freeze where we are now.
        let elapsed = s["elapsed"] as? Double
        let ts = s["timestamp"] as? Double
        let samePair = elapsed == reportedElapsed && ts == reportedTimestamp
        // A seek in flight holds the position, but never across a track change.
        let seekLocked = !trackChanged && (optimisticSeekUntil.map { now < $0 } ?? false)
        if !seekLocked {
            optimisticSeekUntil = nil
            if trackChanged {
                elapsedAtTimestamp = elapsed ?? 0
                timestamp = ts.map { min(Date(timeIntervalSince1970: $0), now) } ?? now
            } else if let elapsed, !samePair {
                elapsedAtTimestamp = elapsed
                timestamp = ts.map { min(Date(timeIntervalSince1970: $0), now) } ?? now
            } else if reportedPlaying && !playing {
                // Freeze at the live position (unless a click already froze it).
                if isPlaying || optimisticPlayingUntil == nil {
                    elapsedAtTimestamp = position(at: now)
                    timestamp = now
                }
            }
            if let r = s["rate"] as? Double, r > 0 { rate = r }
        }
        reportedElapsed = elapsed
        reportedTimestamp = ts
        reportedPlaying = playing

        if let until = optimisticPlayingUntil, now < until, playing != isPlaying {
            // keep optimistic value until the player catches up
        } else {
            optimisticPlayingUntil = nil
            if playing != isPlaying {
                if !playing { elapsedAtTimestamp = position(at: now); timestamp = now }
                isPlaying = playing
            }
        }
        if isPlaying { pausedSince = nil } else if pausedSince == nil { pausedSince = now }

        // Artwork. Keep what's showing until a *different* image actually arrives; players
        // briefly drop the artwork id when pausing / resuming, which mustn't flash.
        if let newArtId = s["artworkId"] as? String, newArtId != artworkId {
            artworkId = newArtId
            if displayedArtId != newArtId, let img = artworkCache[newArtId] {
                artwork = img
                displayedArtId = newArtId
                artworkTimeout?.cancel()
            }
        }
        if trackChanged {
            // New track whose cover hasn't arrived: hold the old one briefly, then fall back.
            artworkTimeout?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.trackKey == key, self.displayedArtId != self.artworkId || self.artworkId == nil else { return }
                if self.artwork != nil { self.artwork = nil; self.displayedArtId = nil }
            }
            artworkTimeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }

        let directExplicit = s["explicit"] as? Bool
        if trackChanged {
            trackKey = key
            explicit = directExplicit ?? false
            if directExplicit == nil {
                explicitResolver.resolve(title: title, artist: artist, album: album, bundleId: bundle) { [weak self] result in
                    guard let self, self.trackKey == key else { return }
                    self.explicit = result
                }
            }
        } else if let d = directExplicit, d != explicit {
            explicit = d
        }
    }

    // MARK: Commands

    func togglePlayPause() {
        guard canControl else { return } // never launch a player implicitly
        let pos = position(at: Date())
        elapsedAtTimestamp = pos
        timestamp = Date()
        isPlaying.toggle()
        pausedSince = isPlaying ? nil : Date()
        optimisticPlayingUntil = Date().addingTimeInterval(1.5)
        bridge.send(isPlaying ? "play" : "pause")
    }

    // Track skipping follows iOS exactly:
    // - Next always goes to the next item (what follows the last one is the player's call,
    //   e.g. Spotify wraps to the first track, paused).
    // - Previous restarts the current item once it's 3s or more in; before that it goes to
    //   the previous item. So pressing it twice quickly goes back a track, and every further
    //   quick press goes back one more.

    /// iOS restarts the item instead of going back once this far in.
    static let restartThreshold: Double = 3

    /// When we last skipped or restarted. Whatever's playing now began no earlier than
    /// that, which we know before the player's own report arrives.
    @ObservationIgnored private var lastSkipAt: Date?

    func next() {
        guard canControl else { return }
        lastSkipAt = Date()
        bridge.send("next")
    }

    func previous() {
        guard canControl else { return }
        let now = Date()
        let cap = lastSkipAt.map { now.timeIntervalSince($0) } ?? -1
        lastSkipAt = now
        // Decided by the helper against the player's live position: ours can lag, or miss a
        // seek the player never announced. Going back always rewinds first, because players
        // such as Spotify and Music apply the same 3s rule themselves and would otherwise
        // merely restart when their clock is a little ahead of ours.
        bridge.send(String(format: "smartprev %.3f %.3f %.3f", Self.restartThreshold, cap, position(at: now)))
    }

    /// The helper's answer to `previous()`.
    func previousHandled(action: String, position: Double) {
        if action == "restart" {
            // Show the restart at once instead of waiting for the player to report it.
            elapsedAtTimestamp = 0
            timestamp = Date()
            optimisticSeekUntil = Date().addingTimeInterval(1.2)
        }
    }

    func seek(to seconds: Double) {
        guard canControl else { return }
        let t = max(0, duration > 0 ? min(seconds, duration) : seconds)
        elapsedAtTimestamp = t
        timestamp = Date()
        optimisticSeekUntil = Date().addingTimeInterval(1.2)
        bridge.send(String(format: "seek %.3f", t))
    }

    func openSourceApp() {
        guard let id = bundleId,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
