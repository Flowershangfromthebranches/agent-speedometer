import AppKit
import SwiftUI

/// A floating, always-on-top strip that never takes focus from the agent app.
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class HUDController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = HUDController()

    @Published var visible: Bool = UserDefaults.standard.object(forKey: "showHUD") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(visible, forKey: "showHUD")
            apply()
        }
    }

    /// Detail card currently open (click a segment to toggle). Hover never changes layout.
    @Published private(set) var openCard: Segment?

    private var panel: HUDPanel?
    private var cardPanel: HUDPanel?
    private var clickMonitor: Any?

    func apply() {
        if visible {
            if panel == nil { makePanel() }
            panel?.orderFrontRegardless()
        } else {
            closeCard()
            panel?.orderOut(nil)
        }
    }

    func toggleCard(_ seg: Segment) {
        if openCard == seg { closeCard() } else { openCard = seg; showCard() }
    }

    func closeCard() {
        openCard = nil
        cardPanel?.orderOut(nil)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    private func showCard() {
        if cardPanel == nil {
            let c = Self.makeBasePanel()
            let host = SizingHostingView(rootView: HUDCardView().environmentObject(Monitor.shared).environmentObject(self))
            host.sizingOptions = [.intrinsicContentSize]
            host.onSizeChange = { [weak self] _ in self?.positionCard() }
            c.contentView = host
            cardPanel = c
        }
        positionCard()
        cardPanel?.orderFrontRegardless()
        // Clicking anywhere in another app closes the card.
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
                Task { @MainActor in HUDController.shared.closeCard() }
            }
        }
    }

    /// Place the card above the bar (or below it when there is no room), never overlapping it.
    private func positionCard() {
        guard let bar = panel, let c = cardPanel, let host = c.contentView else { return }
        let size = host.intrinsicContentSize
        guard size.width > 0, size.height > 0 else { return }
        let vf = (bar.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var origin = NSPoint(x: bar.frame.minX, y: bar.frame.maxY - 8)
        if origin.y + size.height > vf.maxY { origin.y = bar.frame.minY - size.height + 8 }
        origin.x = min(max(origin.x, vf.minX), max(vf.minX, vf.maxX - size.width))
        c.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private static func makeBasePanel() -> HUDPanel {
        let p = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 40),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        return p
    }

    private func makePanel() {
        let p = Self.makeBasePanel()
        p.delegate = self
        panel = p

        let host = SizingHostingView(rootView: HUDRootView().environmentObject(Monitor.shared).environmentObject(self))
        host.sizingOptions = [.intrinsicContentSize]
        host.onSizeChange = { [weak self] size in self?.resize(to: size) }
        p.contentView = host

        if let saved = UserDefaults.standard.string(forKey: "hudOrigin") {
            p.setFrameOrigin(NSPointFromString(saved))
        } else if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: vf.midX - 260, y: vf.minY + 24))
        }
        resize(to: host.intrinsicContentSize)
    }

    /// Keep the bottom-left corner fixed when the bar's text width changes.
    private func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0, let p = panel, p.frame.size != size else { return }
        var f = p.frame
        f.size = size
        p.setFrame(f, display: true)
        keepOnScreen()
        if openCard != nil { positionCard() }
    }

    private func keepOnScreen() {
        guard let p = panel, let screen = p.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        var f = p.frame
        if f.maxY > vf.maxY { f.origin.y = vf.maxY - f.height }
        if f.minX < vf.minX { f.origin.x = vf.minX }
        if f.maxX > vf.maxX { f.origin.x = max(vf.minX, vf.maxX - f.width) }
        if f.origin != p.frame.origin { p.setFrameOrigin(f.origin) }
    }

    nonisolated func windowDidMove(_ notification: Notification) {
        Task { @MainActor in
            guard let p = self.panel else { return }
            UserDefaults.standard.set(NSStringFromPoint(p.frame.origin), forKey: "hudOrigin")
            if self.openCard != nil { self.positionCard() }
        }
    }
}

/// Reports SwiftUI's ideal size so the panel can follow it.
final class SizingHostingView<Content: View>: NSHostingView<Content> {
    var onSizeChange: ((CGSize) -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onSizeChange?(self.intrinsicContentSize)
        }
    }
}

/// Drag to move the panel; a click without movement calls `onClick`.
private struct WindowDragHandle: NSViewRepresentable {
    var onClick: () -> Void

    final class DragView: NSView {
        var onClick: () -> Void = {}
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let start = event.locationInWindow
            while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
                if next.type == .leftMouseUp { onClick(); return }
                let p = next.locationInWindow
                if hypot(p.x - start.x, p.y - start.y) > 3 {
                    window.performDrag(with: event)
                    return
                }
            }
        }
    }
    func makeNSView(context: Context) -> NSView {
        let v = DragView(); v.onClick = onClick; return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? DragView)?.onClick = onClick }
}

struct HUDRootView: View {
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var hud: HUDController

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(hud.openCard == .sessions ? 0.10 : 0))
                WindowDragHandle { hud.toggleCard(.sessions) }
                HStack(spacing: 5) {
                    Image(systemName: monitor.stats?.source == .codex ? "chevron.left.forwardslash.chevron.right" : "sparkle")
                        .font(.system(size: 10, weight: .semibold))
                    Text(modelLabel)
                        .font(.system(size: 11.5))
                    if monitor.pinnedPath != nil {
                        Image(systemName: "pin.fill").font(.system(size: 8))
                    }
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(.tertiary)
                .allowsHitTesting(false)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            .fixedSize()
            .help("点击切换会话 · 拖动移动位置\n当前：\(monitor.stats?.projectName ?? "—")")

            StatusBarView(
                stats: monitor.stats,
                active: hud.openCard,
                onTap: { hud.toggleCard($0) }
            )
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(hudBackground(radius: 11))
        .padding(10) // room for the shadow
        .environment(\.colorScheme, .dark)
        .fixedSize()
        .contextMenu {
            Button("打开设置…") { SettingsWindow.show() }
            Button("隐藏悬浮条") { HUDController.shared.visible = false }
        }
    }

    private var modelLabel: String {
        guard let s = monitor.stats else { return "AgentPulse" }
        return s.model ?? s.source.displayName
    }

}

/// The detail card, in its own panel so opening it never moves or resizes the bar.
struct HUDCardView: View {
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var hud: HUDController

    var body: some View {
        Group {
            if hud.openCard == .sessions {
                SessionListView(compact: false) { hud.closeCard() }
                    .padding(12)
                    .frame(width: 360)
                    .background(hudBackground(radius: 14))
            } else if let seg = hud.openCard, let s = monitor.stats {
                CardFor(seg: seg, s: s)
                    .padding(16)
                    .background(hudBackground(radius: 14))
                    .onTapGesture { hud.closeCard() }
            }
        }
        .padding(10)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}

func hudBackground(radius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
        .fill(Color(white: 0.13).opacity(0.94))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(Color.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
}
