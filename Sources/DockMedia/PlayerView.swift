import SwiftUI

// MARK: - Hover (driven by the panel controller; works even though the app is never active)

private struct PanelUIKey: EnvironmentKey { static let defaultValue: PanelUIState? = nil }
extension EnvironmentValues {
    var panelUI: PanelUIState? {
        get { self[PanelUIKey.self] }
        set { self[PanelUIKey.self] = newValue }
    }
}

struct HoverReader<Content: View>: View {
    @Environment(\.panelUI) private var ui
    @State private var frame: CGRect = .zero
    var inset: CGFloat = 0
    @ViewBuilder var content: (Bool) -> Content

    var body: some View {
        let hovered = ui?.mouse.map { frame.insetBy(dx: inset, dy: inset).contains($0) } ?? false
        content(hovered)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("panel")) } action: { frame = $0 }
    }
}

// MARK: - Player

/// Content only: it's drawn straight onto the Dock's own Liquid Glass, inside the
/// slot DockMedia reserves in the Dock, so there's no glass or window chrome here.
struct PlayerView: View {
    let model: NowPlayingModel
    let ui: PanelUIState

    var body: some View {
        let m = ui.metrics
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                ArtworkView(image: model.artwork, size: m.icon, radius: m.artRadius)
                    .onTapGesture { model.openSourceApp() }
                    .help(model.appName.map { "Open \($0)" } ?? "")

                InfoColumn(model: model, ui: ui)
                    .padding(.leading, m.artGap)
                    .padding(.trailing, m.artGap * 0.6)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ControlsView(model: model, ui: ui)
            }
            .padding(.leading, m.inset)
            .padding(.trailing, m.inset * 0.4)
            .frame(width: m.playerWidth, height: m.platter)

            DockDivider(height: m.dividerHeight)
                .frame(width: m.dividerWidth, height: m.platter)
        }
        .frame(width: m.width, height: m.platter)
        // Appear / disappear like a system Now Playing view: fade with a slight settle and blur.
        .opacity(ui.showing ? 1 : 0)
        .scaleEffect(ui.showing ? 1 : 0.96)
        .blur(radius: ui.showing ? 0 : 4)
        .animation(.smooth(duration: 0.45), value: ui.showing)
        .opacity(ui.revealed ? 1 : 0)
        .coordinateSpace(.named("panel"))
        .environment(\.panelUI, ui)
        .modifier(GlassScheme(dark: ui.glassDark))
    }
}

/// The Dock's own divider: a 1pt hairline as tall as an icon tile. Measured on the real
/// Dock it lightens the glass by a constant ~65/255 on both tones (37→102 on dark glass,
/// 170→235 on light). Our window can't blend with the Dock's pixels, so reproduce that
/// with white at the matching opacity for each tone.
struct DockDivider: View {
    let height: CGFloat
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(scheme == .dark ? 0.30 : 0.76))
            .frame(width: 1, height: height)
    }
}

/// Match text colour to the glass's actual tone when known.
struct GlassScheme: ViewModifier {
    let dark: Bool?
    func body(content: Content) -> some View {
        if let dark { content.environment(\.colorScheme, dark ? .dark : .light) } else { content }
    }
}

// MARK: - Artwork (sized and placed exactly like a Dock icon)

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
                    .id(ObjectIdentifier(image))
            } else {
                shape.fill(LinearGradient(colors: [Color(white: 0.56), Color(white: 0.38)], startPoint: .top, endPoint: .bottom))
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        // Dock icons carry a soft contact shadow and a faint edge.
        .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.28), radius: 1.2, y: 0.6)
        .animation(.smooth(duration: 0.5), value: image.map(ObjectIdentifier.init))
    }
}

// MARK: - Title / artist / progress

struct InfoColumn: View {
    let model: NowPlayingModel
    let ui: PanelUIState
    @State private var dragFraction: Double?

    var body: some View {
        let m = ui.metrics
        HoverReader(inset: -2) { hovered in
            let showTimes = (hovered || dragFraction != nil) && model.duration > 0
            let live = model.isPlaying && ui.revealed && ui.showing && dragFraction == nil
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !live)) { tl in
                let duration = model.duration
                let pos = dragFraction.map { $0 * duration } ?? model.position(at: tl.date)
                VStack(alignment: .leading, spacing: 0) {
                    // Title + artist change together with the system's blur-replace transition.
                    VStack(alignment: .leading, spacing: 0) {
                        TitleRow(model: model, ui: ui)
                        ZStack(alignment: .leading) {
                            Text(model.artist.isEmpty ? (model.appName ?? " ") : model.artist)
                                .font(.system(size: m.subtitleSize))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .opacity(showTimes ? 0 : 1)
                            HStack {
                                Text(Self.format(pos, total: duration))
                                Spacer(minLength: 4)
                                Text("-" + Self.format(max(0, duration - pos), total: duration))
                            }
                            .font(.system(size: m.timeSize, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .opacity(showTimes ? 1 : 0)
                        }
                        .animation(.smooth(duration: 0.22), value: showTimes)
                    }
                    .id(model.trackID)
                    .transition(.blurReplace)

                    Spacer(minLength: 0)
                    ProgressBar(model: model, ui: ui, fraction: duration > 0 ? pos / duration : 0,
                                emphasized: showTimes, dragFraction: $dragFraction)
                        .opacity(duration > 0 ? 1 : 0.4)
                }
                .animation(.smooth(duration: 0.4), value: model.trackID)
            }
            .frame(height: m.icon)
            .contentShape(Rectangle())
        }
    }

    static func format(_ t: Double, total: Double) -> String {
        guard t.isFinite else { return "0:00" }
        let s = Int(t.rounded(.down))
        let h = s / 3600, mi = (s % 3600) / 60, se = s % 60
        if total >= 3600 { return String(format: "%d:%02d:%02d", h, mi, se) }
        return String(format: "%d:%02d", mi + h * 60, se)
    }
}

struct TitleRow: View {
    let model: NowPlayingModel
    let ui: PanelUIState

    var body: some View {
        let m = ui.metrics
        HStack(spacing: 4) {
            MarqueeText(
                text: model.title,
                font: .system(size: m.titleSize, weight: .semibold),
                // Scrolls whenever the player is on screen, like the iPhone's Now Playing.
                scrolling: ui.revealed && ui.showing,
                restartToken: ui.trackChangeDate
            )
            if model.explicit {
                ExplicitBadge(size: (m.titleSize * 0.9).rounded())
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .foregroundStyle(.primary)
        .animation(.smooth(duration: 0.3), value: model.explicit)
    }
}

/// The Apple Music "E" marker.
struct ExplicitBadge: View {
    let size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
            .fill(.secondary)
            .frame(width: size, height: size)
            .overlay {
                Text("E")
                    .font(.system(size: size * 0.7, weight: .bold))
                    .foregroundStyle(.black.opacity(0.85))
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
            .accessibilityLabel("Explicit")
    }
}

/// Thin capsule that thickens on hover (like iOS) and scrubs on drag.
struct ProgressBar: View {
    let model: NowPlayingModel
    let ui: PanelUIState
    let fraction: Double
    let emphasized: Bool
    @Binding var dragFraction: Double?

    var body: some View {
        let m = ui.metrics
        let h = emphasized ? m.barHeight + 2 : m.barHeight
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.22))
                Capsule().fill(.primary.opacity(0.9))
                    .frame(width: max(h, w * min(max(fraction, 0), 1)))
            }
            .frame(height: h)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard model.duration > 0 else { return }
                        ui.scrubbing = true
                        dragFraction = min(max(v.location.x / max(w, 1), 0), 1)
                    }
                    .onEnded { v in
                        guard model.duration > 0 else { return }
                        model.seek(to: min(max(v.location.x / max(w, 1), 0), 1) * model.duration)
                        dragFraction = nil
                        ui.scrubbing = false
                    }
            )
        }
        .frame(height: m.barHeight + 2)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: emphasized)
    }
}

/// Single line text that scrolls when it doesn't fit, like Now Playing on iPhone: it rests
/// at the start for a beat, scrolls one full length until the copy behind it lands exactly
/// where it began, rests again, and repeats, for as long as it's on screen. Each time it
/// appears (the Dock opens, a new track starts) it begins again from rest.
struct MarqueeText: View {
    let text: String
    let font: Font
    let scrolling: Bool
    let restartToken: Date

    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var startDate = Date()

    private let gap: CGFloat = 28
    private let speed: CGFloat = 30 // pt/s
    /// Rest before the first pass after appearing.
    private let firstDelay: Double = 1.2
    /// Rest at the start between passes.
    private let pause: Double = 2.5

    var body: some View {
        let overflow = textWidth > boxWidth + 0.5 && boxWidth > 0
        Text(text).font(font).lineLimit(1).opacity(0)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .background(alignment: .leading) {
                Text(text).font(font).fixedSize().hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            }
            .overlay(alignment: .leading) {
                if overflow {
                    TimelineView(.animation(minimumInterval: 1 / 60, paused: !scrolling)) { tl in
                        let x = scrolling ? offset(at: tl.date) : 0
                        HStack(spacing: gap) {
                            Text(text).font(font).fixedSize()
                            Text(text).font(font).fixedSize()
                        }
                        .offset(x: x)
                        .frame(width: boxWidth, alignment: .leading)
                        .clipped()
                        .mask(edgeFade(leading: Double(min(1, -x / 14))))
                    }
                } else {
                    Text(text).font(font).lineLimit(1)
                }
            }
            .onChange(of: scrolling, initial: true) { _, s in if s { startDate = Date() } }
            .onChange(of: restartToken) { _, _ in startDate = Date() }
            .onChange(of: text) { _, _ in startDate = Date() }
    }

    /// Trailing edge always fades (there's more text); the leading edge only while moving.
    private func edgeFade(leading: Double) -> some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(1 - leading), location: 0),
                .init(color: .black, location: 0.06),
                .init(color: .black, location: 0.88),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }

    private func offset(at date: Date) -> CGFloat {
        let cycle = textWidth + gap
        let scrollDur = Double(cycle / speed)
        var t = date.timeIntervalSince(startDate) - firstDelay
        if t < 0 { return 0 }
        // First pass starts right after the initial delay, later passes after `pause`.
        if t < scrollDur { return -CGFloat(t) * speed }
        t = (t - scrollDur).truncatingRemainder(dividingBy: pause + scrollDur)
        if t < pause { return 0 }
        return -CGFloat(t - pause) * speed
    }
}

// MARK: - Controls

struct ControlsView: View {
    let model: NowPlayingModel
    let ui: PanelUIState

    var body: some View {
        let m = ui.metrics
        HStack(spacing: 0) {
            ControlButton(symbol: "backward.fill", glyph: m.skipGlyph, size: m.button, enabled: true) { model.previous() }
            ControlButton(symbol: model.isPlaying ? "pause.fill" : "play.fill", glyph: m.playGlyph, size: m.button, enabled: true) {
                model.togglePlayPause()
            }
            ControlButton(symbol: "forward.fill", glyph: m.skipGlyph, size: m.button, enabled: true) { model.next() }
        }
        .frame(height: m.platter)
    }
}

struct ControlButton: View {
    let symbol: String
    let glyph: CGFloat
    let size: CGFloat
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        HoverReader { hovered in
            Button(action: action) {
                // Fixed square frame: play and pause have different widths, so a fixed frame
                // keeps the glyph's centre (and its neighbours) from moving when it toggles.
                Image(systemName: symbol)
                    .font(.system(size: glyph, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.smooth(duration: 0.3), value: symbol)
                    // A triangle's visual centre sits right of its bounding box's centre;
                    // nudge it like Apple's players do so play reads as centred.
                    .offset(x: symbol == "play.fill" ? glyph * 0.05 : 0)
                    .frame(width: size, height: size)
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle(hovered: hovered && enabled))
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.35)
        }
    }
}

struct PressableStyle: ButtonStyle {
    let hovered: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(
                Circle().fill(.primary.opacity(configuration.isPressed ? 0.18 : (hovered ? 0.10 : 0)))
            )
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
            .animation(.smooth(duration: 0.18), value: hovered)
    }
}
