import Cocoa
import Combine
import GemmaFindCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    private let statusMenuItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause Indexing", action: #selector(togglePause), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        setupStatusItem()

        HotKeyManager.shared.onActivate = { SearchPanelController.shared.toggle() }
        if !HotKeyManager.shared.register() {
            let alert = NSAlert()
            alert.messageText = "⌃⇧F is already in use"
            alert.informativeText = "Another app has claimed the ⌃⇧F shortcut. You can still open GemmaFind from the menu bar."
            alert.runModal()
        }

        AppModel.shared.start()
        AppModel.shared.$progress.combineLatest(AppModel.shared.$modelState)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.refreshStatus() }
            .store(in: &cancellables)

        // First launch: show the panel so people discover it.
        if AppModel.shared.testFolder == nil, !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { SearchPanelController.shared.show() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SearchPanelController.shared.show()
        return true
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "GemmaFind")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        let search = NSMenuItem(title: "Search…", action: #selector(showPanel), keyEquivalent: "f")
        search.keyEquivalentModifierMask = [.control, .shift]
        menu.addItem(search)
        menu.addItem(.separator())
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(pauseItem)
        menu.addItem(NSMenuItem(title: "Rebuild Index", action: #selector(rebuildIndex), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit GemmaFind", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) { refreshStatus() }

    private func refreshStatus() {
        let model = AppModel.shared
        statusMenuItem.title = model.statusLine
        pauseItem.title = model.progress.phase == .paused ? "Resume Indexing" : "Pause Indexing"
        statusItem.button?.toolTip = "GemmaFind — \(model.statusLine)"
    }

    @objc func showPanel() { SearchPanelController.shared.show() }
    @objc private func togglePause() { AppModel.shared.togglePause() }

    @objc private func rebuildIndex() {
        let alert = NSAlert()
        alert.messageText = "Rebuild the whole index?"
        alert.informativeText = "All files will be re-read and re-embedded. Search keeps working with partial results meanwhile."
        alert.addButton(withTitle: "Rebuild")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { AppModel.shared.reindexAll() }
    }

    @objc func openSettings() {
        SearchPanelController.shared.hide()
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "GemmaFind Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView().environmentObject(AppModel.shared))
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
