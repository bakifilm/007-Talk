import AppKit
import Combine
import SwiftUI
import UserNotifications

@main
struct Talk007App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView().environmentObject(AppStore.shared)
        }
    }
}

/// Owns the menu bar item, its popover and the main chat window (plain AppKit for reliability).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    static private(set) var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var window: NSWindow?
    private var viewerWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var store: AppStore { AppStore.shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        store.applyDockPolicy()
        UNUserNotificationCenter.current().delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
        }

        let hosting = NSHostingController(rootView: MenuBarView().environmentObject(store))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = false

        store.$rooms
            .combineLatest(store.$loginState)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)
        updateStatusItem()

        if store.loginState != .loggedIn { showMainWindow() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await store.refreshRooms() }
    }

    // MARK: Menu bar

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let count = store.unreadRoomCount
        let image = NSImage(systemSymbolName: count > 0 ? "bubble.left.fill" : "bubble.left",
                            accessibilityDescription: "007 Talk")
        image?.isTemplate = true
        button.image = image
        button.title = count > 0 ? " \(count)" : ""
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            Task { await store.refreshRooms() }
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: Main window

    func showMainWindow(select token: String? = nil) {
        popover.performClose(nil)
        if let token { store.selectedToken = token }

        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            w.title = "007 Talk"
            w.contentView = NSHostingView(rootView: MainView().environmentObject(store))
            w.minSize = NSSize(width: 640, height: 420)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            w.setFrameAutosaveName("MainWindow")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Media viewer

    func showViewer(items: [MediaItem], index: Int) {
        guard !items.isEmpty else { return }
        let content = NSHostingView(rootView: MediaViewer(items: items, index: index).environmentObject(store))
        if let w = viewerWindow {
            w.contentView = content
        } else {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = .black
            w.isReleasedWhenClosed = false
            w.contentView = content
            w.center()
            w.setFrameAutosaveName("MediaViewer")
            viewerWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        viewerWindow?.makeKeyAndOrderFront(nil)
    }

    // Only the main window drives the read state.
    private func isMain(_ n: Notification) -> Bool { (n.object as? NSWindow) === window }
    func windowDidBecomeKey(_ notification: Notification) { if isMain(notification) { store.isChatVisible = true } }
    func windowDidResignKey(_ notification: Notification) { if isMain(notification) { store.isChatVisible = false } }
    func windowWillClose(_ notification: Notification) { if isMain(notification) { store.isChatVisible = false } }

    // MARK: Notifications

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let token = response.notification.request.content.userInfo["token"] as? String
        Task { @MainActor in AppDelegate.shared?.showMainWindow(select: token) }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
