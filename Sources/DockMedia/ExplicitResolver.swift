import Foundation

/// Determines whether the current track is explicit when the player doesn't
/// publish that flag through MediaRemote (Apple Music does; Spotify doesn't).
///  - Spotify: asks Spotify for the current track ID (AppleScript), then reads
///    the public embed metadata for that exact track.
///  - Others: best-effort lookup in the iTunes Search API.
final class ExplicitResolver {
    private var cache: [String: Bool] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        return URLSession(configuration: c)
    }()
    private let scriptQueue = DispatchQueue(label: "explicit.applescript")

    func resolve(title: String, artist: String, album: String, bundleId: String?, completion: @escaping (Bool) -> Void) {
        let key = "\(bundleId ?? "")|\(title)|\(artist)"
        if let v = cache[key] { completion(v); return }
        let finish: (Bool?) -> Void = { [weak self] v in
            DispatchQueue.main.async {
                if let v { self?.cache[key] = v }
                completion(v ?? false)
            }
        }
        if bundleId == "com.spotify.client" {
            spotifyTrackId(expectedTitle: title) { [weak self] id in
                guard let self else { return }
                if let id {
                    self.spotifyExplicit(trackId: id) { v in
                        if let v { finish(v) } else { self.itunesExplicit(title: title, artist: artist, album: album, completion: finish) }
                    }
                } else {
                    self.itunesExplicit(title: title, artist: artist, album: album, completion: finish)
                }
            }
        } else {
            itunesExplicit(title: title, artist: artist, album: album, completion: finish)
        }
    }

    // MARK: Spotify

    private func spotifyTrackId(expectedTitle: String, attempt: Int = 0, completion: @escaping (String?) -> Void) {
        scriptQueue.async {
            let src = """
            tell application id "com.spotify.client"
                if it is running then return (id of current track) & "\\n" & (name of current track)
            end tell
            return ""
            """
            var err: NSDictionary?
            let res = NSAppleScript(source: src)?.executeAndReturnError(&err).stringValue ?? ""
            let parts = res.components(separatedBy: "\n")
            if parts.count >= 2, parts[0].hasPrefix("spotify:track:") {
                // Make sure Spotify has moved on to the track MediaRemote reported.
                if Self.normalize(parts[1]) == Self.normalize(expectedTitle) || attempt >= 3 {
                    completion(String(parts[0].dropFirst("spotify:track:".count)))
                } else {
                    self.scriptQueue.asyncAfter(deadline: .now() + 0.5) {
                        self.spotifyTrackId(expectedTitle: expectedTitle, attempt: attempt + 1, completion: completion)
                    }
                }
            } else {
                completion(nil)
            }
        }
    }

    private func spotifyExplicit(trackId: String, completion: @escaping (Bool?) -> Void) {
        guard let url = URL(string: "https://open.spotify.com/embed/track/\(trackId)") else { completion(nil); return }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: req) { data, _, _ in
            guard let data, let html = String(data: data, encoding: .utf8),
                  let r = html.range(of: #""isExplicit":(true|false)"#, options: .regularExpression) else {
                completion(nil); return
            }
            completion(html[r].hasSuffix("true"))
        }.resume()
    }

    // MARK: iTunes Search

    private func itunesExplicit(title: String, artist: String, album: String, completion: @escaping (Bool?) -> Void) {
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            .init(name: "term", value: "\(Self.stripDecorations(title)) \(artist)"),
            .init(name: "entity", value: "song"),
            .init(name: "limit", value: "25"),
        ]
        guard let url = comps.url else { completion(nil); return }
        session.dataTask(with: url) { data, _, _ in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = obj["results"] as? [[String: Any]] else { completion(nil); return }
            let nt = Self.normalize(Self.stripDecorations(title))
            let na = Self.normalize(artist)
            let matches = results.filter {
                let t = Self.normalize(Self.stripDecorations($0["trackName"] as? String ?? ""))
                let a = Self.normalize($0["artistName"] as? String ?? "")
                return t == nt && (a.contains(na) || na.contains(a))
            }
            guard !matches.isEmpty else { completion(nil); return }
            let nAlbum = Self.normalize(album)
            let sameAlbum = matches.filter { Self.normalize($0["collectionName"] as? String ?? "").hasPrefix(nAlbum) }
            let pool = sameAlbum.isEmpty ? matches : sameAlbum
            // The store sometimes only lists the "cleaned" edit; its existence means the
            // original (which streaming services play by default) is explicit.
            completion(pool.contains { ["explicit", "cleaned"].contains($0["trackExplicitness"] as? String ?? "") })
        }.resume()
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Removes " - Remastered 2011", "(feat. X)" etc.
    static func stripDecorations(_ s: String) -> String {
        var t = s
        if let r = t.range(of: " - ") { t = String(t[..<r.lowerBound]) }
        t = t.replacingOccurrences(of: #"\s*[\(\[](feat|ft|with)\.?[^\)\]]*[\)\]]"#, with: "", options: [.regularExpression, .caseInsensitive])
        return t.trimmingCharacters(in: .whitespaces)
    }
}
