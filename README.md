# DockMedia

A Now Playing player that lives *inside* your Dock, an iPhone lock-screen style mini
player on the Dock's own Liquid Glass.

- Album art sized and placed exactly like a Dock icon, song title with the **E**
  explicit marker, artist, progress bar
- Long titles scroll on their own whenever the Dock is open, like iPhone Now Playing
- Hover the progress bar to enlarge it and see elapsed / remaining time; click or drag to seek
- Previous · Play/Pause · Next, with iPhone skip rules: Previous restarts the song once it's 3s in, otherwise (or pressed again) goes back a song; skipping past an album's end keeps the player up
- Works with anything that shows up in Control Center's Now Playing
  (Spotify, Apple Music, browsers, Podcasts, …)
- Click the artwork to open the playing app. Right-click the player (or use the
  optional menu bar icon, off by default) for Open at Login, Show in Menu Bar, Quit.

## Requirements

- macOS 26 or later on Apple silicon
- Xcode or the Command Line Tools, to build
- The Dock at the bottom of the screen (left and right Docks aren't supported)

## Build & run

```sh
./build.sh            # builds build/DockMedia.app
./build.sh --install  # also copies it to /Applications and launches it
```

DockMedia turns on Open at Login the first time it runs from `/Applications`; switch it
off from the player's right-click menu.

## Permissions

| Permission | Needed for | Without it |
| --- | --- | --- |
| Accessibility (required, prompted on first launch) | Finding the player's slot in the Dock | The player can't appear |
| Screen Recording (optional, add DockMedia manually in System Settings) | Matching text tone to the glass; hiding Dock restarts behind a snapshot | Text follows the system appearance; Dock restarts are visible |
| Automation for Spotify (optional, prompted once) | Reading the Spotify track ID for the **E** marker | Falls back to the iTunes lookup |

## Privacy

There are no accounts, analytics or telemetry. The only network requests look up the
**E** marker: for Spotify, the public embed page of the current track; for other
sources, the iTunes Search API with the track title and artist. Screen Recording is only
used on the Dock's own area, and images are never saved or sent anywhere.

## Limitations

DockMedia depends on private macOS interfaces (MediaRemote, CoreDock) and on the Dock's
internal preferences, so a macOS update can break it. It edits your Dock's layout and
restarts the Dock whenever the player appears or goes away. If it crashes, its empty slot
can stay in the Dock until it's next launched.

## Uninstall

Quit DockMedia first (right-click the player, or `pkill -x DockMedia`) so it can remove
its slot from the Dock, then delete `/Applications/DockMedia.app`.

## How it works

- **A real slot in the Dock:** DockMedia adds 7 spacer tiles plus a half-width one that
  holds a divider (labelled "DockMedia" and marked `dockmedia-slot`) at the start of the
  Dock's right-hand section, after the divider. The Dock lays them out
  like any other tile, so its glass extends under the player and the whole Dock (apps,
  player and Trash) stays centered. DockMedia draws only the content, in a transparent
  window just above the Dock, tracking the spacers' live frames through Accessibility, so it
  follows auto-hide and magnification frame for frame.
- **Slot lifecycle:** the player shows while something is playing (or paused for under
  5 minutes, like the iPhone lock screen). The slot is added the moment media starts and
  removed the moment it ends (and on quit), whether or not the Dock is showing. Changing it
  restarts the Dock. When the Dock is showing, that restart is hidden: a frozen snapshot of
  the Dock covers it, auto-hide is suspended so the new Dock comes back shown, and once the
  new layout has settled the snapshot crossfades into it (about 0.6s). Auto-hide returns as
  soon as the new Dock is up, so apps opening right then don't lay out around it. Your own
  spacers are never touched. The Dock sometimes rewrites its preferences and drops unknown keys, so the
  slot is also recognised by its label and position; a second slot is never added.
- **No magnification over the player:** near the player the Dock's magnified size is eased
  down to the tile size live (CoreDock), and restored as the pointer leaves and on quit.
- **Text tone follows the glass:** Liquid Glass takes its tone from what's behind it, so
  the player samples the glass (Screen Recording) instead of trusting the system appearance.
- **Now playing:** since macOS 15.4 MediaRemote only talks to Apple-signed processes,
  so a small helper dylib (`Helper/MediaRemoteHelper.m`) is hosted inside the system's
  `/usr/bin/perl` and streams now-playing JSON over a pipe; commands go back over stdin.
- **Explicit marker:** Apple Music provides it directly. For Spotify, DockMedia asks
  Spotify for the track ID (one-time Automation prompt) and reads Spotify's public
  embed metadata; other sources fall back to the iTunes Search API.

## License

[MIT](LICENSE). DockMedia isn't affiliated with Apple or Spotify.

