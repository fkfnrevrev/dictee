// La petite barre flottante en bas de l'ecran.

import AppKit
import SwiftUI

struct OverlayView: View {
    @ObservedObject var model: AppModel
    @AppStorage(Pref.barVisible) private var visible = true
    @AppStorage(Pref.barAlways) private var always = true
    @AppStorage(Pref.barSize) private var size = 1.0
    @AppStorage(Pref.barOpacity) private var opacity = 0.92
    @AppStorage(Pref.barStyle) private var style = "orange"

    private var gradient: LinearGradient {
        switch style {
        case "noir":
            return LinearGradient(colors: [Color(red: 0.19, green: 0.19, blue: 0.21), Color(red: 0.02, green: 0.02, blue: 0.02)],
                                  startPoint: .top, endPoint: .bottom)
        case "graphite":
            return LinearGradient(colors: [Color(red: 0.36, green: 0.37, blue: 0.40), Color(red: 0.16, green: 0.17, blue: 0.19)],
                                  startPoint: .top, endPoint: .bottom)
        case "vert":
            return LinearGradient(colors: [Color(red: 0.20, green: 0.80, blue: 0.42), Color(red: 0.07, green: 0.52, blue: 0.25)],
                                  startPoint: .top, endPoint: .bottom)
        default:
            // Orange #FB6C00 qui se fond dans le noir.
            return LinearGradient(stops: [
                .init(color: Color(red: 251 / 255, green: 108 / 255, blue: 0), location: 0),
                .init(color: Color(red: 0.35, green: 0.13, blue: 0.02), location: 0.6),
                .init(color: Color(red: 0.03, green: 0.03, blue: 0.03), location: 1),
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    var body: some View {
        let phase = model.displayedPhase
        let active = phase == .recording || phase == .transcribing
        let scale = CGFloat(size)
        let width = (active ? 68 : 38) * scale
        let height = (active ? 20 : 8) * scale
        let shown = visible && (always || active)

        ZStack {
            Capsule()
                .fill(gradient)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.6))
            if phase == .recording {
                LevelBars(level: model.level, maxHeight: height * 0.62, scale: scale)
                    .transition(.opacity)
            } else if phase == .transcribing {
                ThinkingDots(scale: scale).transition(.opacity)
            }
        }
        .frame(width: width, height: height)
        .shadow(color: .black.opacity(0.35), radius: 5 * scale, y: 2)
        .opacity(shown ? (phase == .loading ? opacity * 0.5 : opacity) : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: active)
        .animation(.easeInOut(duration: 0.2), value: shown)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 16)
    }
}

/// Petites barres qui suivent le volume de la voix.
struct LevelBars: View {
    var level: Double
    var maxHeight: CGFloat
    var scale: CGFloat
    private let weights = [0.35, 0.6, 0.85, 1.0, 0.85, 0.6, 0.35]

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.2 * scale) {
                ForEach(0..<weights.count, id: \.self) { i in
                    let wobble = 0.75 + 0.25 * sin(t * 9 + Double(i) * 1.3)
                    Capsule()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: 2 * scale,
                               height: max(2 * scale, maxHeight * CGFloat(min(1, level * weights[i] * wobble))))
                }
            }
        }
    }
}

/// Trois points qui pulsent pendant la transcription.
struct ThinkingDots: View {
    var scale: CGFloat

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4 * scale) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.white.opacity(0.35 + 0.6 * max(0, sin(t * 6 - Double(i) * 0.8))))
                        .frame(width: 3.2 * scale, height: 3.2 * scale)
                }
            }
        }
    }
}

/// Fenetre transparente, sans clic, presente sur tous les bureaux et au-dessus des apps en plein ecran.
final class OverlayPanel {
    private let panel: NSPanel
    private let size = NSSize(width: 320, height: 90)

    init(model: AppModel) {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: OverlayView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host

        let center = NotificationCenter.default
        center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reposition()
        }
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) {
            [weak self] _ in self?.reposition()
        }
        reposition()
        panel.orderFrontRegardless()
    }

    /// Place la barre en bas, au milieu de l'ecran ou se trouve la souris.
    func reposition() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let offset = CGFloat(UserDefaults.standard.double(forKey: Pref.barOffset))
        let area = screen.visibleFrame
        let origin = NSPoint(x: area.midX - size.width / 2, y: area.minY + offset)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }
}
