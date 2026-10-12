import Cocoa
import GemmaFindCore
import Quartz
import SwiftUI

/// Borderless floating panel that can become key (so the search field gets typing focus).
final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        SearchPanelController.shared.hide()
    }
}

/// Shows/hides the Spotlight-like search panel and handles panel-wide shortcuts.
@MainActor
final class SearchPanelController: NSObject, NSWindowDelegate {
    static let shared = SearchPanelController()

    private var panel: SearchPanel?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    /// Bumped each time the panel is shown, so the search field re-focuses.
    private(set) var showCount = 0

    static let panelSize = NSSize(width: 900, height: 560)

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        if panel == nil { build() }
        guard let panel else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        position(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        showCount += 1
        NotificationCenter.default.post(name: .gemmaFindFocusSearch, object: nil)
        installKeyMonitor()
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
        panel.orderOut(nil)
        removeKeyMonitor()
        NotificationCenter.default.post(name: .gemmaFindPanelHidden, object: nil)
    }

    /// Renders the panel's content to a PNG (behind-window blur is replaced by a solid fill).
    func snapshot(to url: URL) {
        guard let view = panel?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: view.bounds.size), xRadius: 18, yRadius: 18).fill()
        rep.draw(in: NSRect(origin: .zero, size: view.bounds.size))
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
           let png = bmp.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }

    private func build() {
        let p = SearchPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView, .resizable],
                            backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.delegate = self
        p.minSize = NSSize(width: 640, height: 380)

        let root = SearchRootView().environmentObject(AppModel.shared)
        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        p.contentView = effect
        panel = p
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        var size = panel.frame.size
        size.width = min(size.width, visible.width - 80)
        size.height = min(size.height, visible.height - 80)
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + visible.height * 0.62 - size.height / 2)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Keep the panel while Quick Look (or a sheet) is in front.
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { return }
        if NSApp.keyWindow is NSOpenPanel { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, !panel.isKeyWindow else { return }
            if NSApp.keyWindow == nil || !(NSApp.keyWindow is SearchPanel) {
                // Hide only when focus moved to another app or window.
                if !NSApp.isActive || NSApp.keyWindow != nil { self.hide() }
            }
        }
    }

    // MARK: Shortcuts

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isKeyWindow == true else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let model = AppModel.shared
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (event.keyCode, flags) {
        case (125, _): model.moveSelection(1); return true                  // ↓
        case (126, _): model.moveSelection(-1); return true                 // ↑
        case (36, .command), (76, .command): model.revealInFinder(); return true  // ⌘↩
        case (36, []), (76, []): model.open(); return true                  // ↩
        case (53, _): hide(); return true                                   // esc
        default: break
        }
        if flags == .command, let ch = event.charactersIgnoringModifiers?.lowercased() {
            switch ch {
            case "y": toggleQuickLook(); return true
            case ",": AppDelegate.shared?.openSettings(); return true
            default: break
            }
        }
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "c" {
            model.copyPath(); return true
        }
        return false
    }

    // MARK: Quick Look

    private let quickLook = QuickLookSource()

    func toggleQuickLook() {
        guard let r = AppModel.shared.selectedResult else { return }
        let ql = QLPreviewPanel.shared()!
        if ql.isVisible { ql.orderOut(nil); return }
        quickLook.url = r.file.url
        ql.dataSource = quickLook
        ql.reloadData()
        ql.makeKeyAndOrderFront(nil)
    }
}

final class QuickLookSource: NSObject, QLPreviewPanelDataSource {
    var url: URL?
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { url as NSURL? }
}

extension Notification.Name {
    static let gemmaFindFocusSearch = Notification.Name("GemmaFindFocusSearch")
    static let gemmaFindPanelHidden = Notification.Name("GemmaFindPanelHidden")
}
