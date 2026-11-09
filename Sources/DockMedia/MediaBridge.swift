import AppKit

/// Talks to the MediaRemote helper (a dylib hosted inside the Apple-signed
/// `/usr/bin/perl`, which is still allowed to read system now-playing data).
final class MediaBridge {
    var onState: (([String: Any]) -> Void)?
    var onArtwork: ((String, Data) -> Void)?
    var onPrevious: ((String, Double) -> Void)?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var buffer = Data()
    private var restartDelay: TimeInterval = 0.5
    private var stopped = false

    private static let loader = """
    use DynaLoader;
    my $h = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
    my $s = DynaLoader::dl_find_symbol($h, "DockMediaHelperRun") or die "symbol";
    DynaLoader::dl_install_xsub("main::run", $s);
    &run();
    """

    private var helperPath: String? {
        if let p = Bundle.main.path(forResource: "MediaRemoteHelper", ofType: "dylib") { return p }
        // Running unbundled (swift run): look next to the executable / in build/.
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for c in [exe.appendingPathComponent("MediaRemoteHelper.dylib"),
                  URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/MediaRemoteHelper.dylib")] {
            if FileManager.default.fileExists(atPath: c.path) { return c.path }
        }
        return nil
    }

    func start() {
        stopped = false
        guard let path = helperPath else {
            NSLog("DockMedia: MediaRemoteHelper.dylib not found")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", Self.loader, path]
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(d) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                let delay = self.restartDelay
                self.restartDelay = min(self.restartDelay * 2, 10)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.start() }
            }
        }
        do {
            try p.run()
            process = p
            stdinHandle = inp.fileHandleForWriting
            buffer.removeAll()
        } catch {
            NSLog("DockMedia: failed to start helper: \(error)")
        }
    }

    func stop() {
        stopped = true
        process?.terminate()
        process = nil
    }

    func send(_ command: String) {
        guard let h = stdinHandle, let d = (command + "\n").data(using: .utf8) else { return }
        do { try h.write(contentsOf: d) } catch { }
    }

    private func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            restartDelay = 0.5
            switch obj["type"] as? String {
            case "artwork":
                if let id = obj["artworkId"] as? String, let b64 = obj["data"] as? String,
                   let data = Data(base64Encoded: b64) {
                    onArtwork?(id, data)
                }
            case "previous":
                onPrevious?(obj["action"] as? String ?? "", obj["position"] as? Double ?? 0)
            default:
                onState?(obj)
            }
        }
    }
}
