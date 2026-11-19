import AppKit
import Darwin
import SwiftUI
import RouteBarCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    private var item: NSStatusItem!
    private var popover: NSPopover!
    private var window: NSWindow?
    private var model: AppModel!
    private var openingPopover = false
    private var instanceLock: SingleInstanceLock?
    private var managerRequested = false
    private let reopenNotification = Notification.Name("io.routebar.app.open-manager")
    private let reopenUser = String(getuid())

    func applicationDidFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let launchedAtLogin = event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
            || event?.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil
        let opensManager = !CommandLine.arguments.contains("--menu-only") && !launchedAtLogin
        let center = DistributedNotificationCenter.default()
        // Subscribe before taking the lock so a simultaneous launch can hand off its request.
        center.addObserver(self, selector: #selector(openManager), name: reopenNotification, object: reopenUser, suspensionBehavior: .deliverImmediately)
        do {
            guard let lock = try SingleInstanceLock.acquire() else {
                if opensManager {
                    center.postNotificationName(reopenNotification, object: reopenUser, userInfo: nil, deliverImmediately: true)
                }
                NSApp.terminate(nil)
                return
            }
            instanceLock = lock
        } catch {
            AppDiagnostics.write("instance-lock-failed: \(error.localizedDescription)")
            if opensManager {
                let alert = NSAlert(error: error)
                alert.messageText = L("无法启动 RouteBar")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
            NSApp.terminate(nil)
            return
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        AppDiagnostics.write("launch version=\(version)")
        NSSetUncaughtExceptionHandler { exception in
            AppDiagnostics.write("uncaught-exception name=\(exception.name.rawValue) reason=\(exception.reason ?? "unknown")")
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        installMainMenu()
        model = AppModel()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: L("RouteBar 路由检查"))
        item.button?.image?.isTemplate = true
        item.button?.title = L(" 路由")
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.target = self; item.button?.action = #selector(togglePopover)
        item.button?.toolTip = L("RouteBar · 只读观察")
        popover = NSPopover(); popover.behavior = .transient; popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MenuContent(model: model))
        model.showWindow = { [weak self] in self?.showManager() }
        model.onStatusChanged = { [weak self] in self?.updateStatus() }
        model.onLanguageChanged = { [weak self] in
            self?.installMainMenu()
        }
        if opensManager || managerRequested { showManager() }
        AppDiagnostics.write("launch-at-login=\(launchedAtLogin)")
    }
    private func installMainMenu() {
        let menu = NSMenu(), applicationItem = NSMenuItem(), applicationMenu = NSMenu()
        let openItem = applicationMenu.addItem(withTitle: L("打开管理窗口"), action: #selector(openManager), keyEquivalent: "1")
        openItem.target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: L("关于 RouteBar"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: L("退出 RouteBar"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu; menu.addItem(applicationItem)
        let editItem = NSMenuItem(), editMenu = NSMenu(title: L("编辑"))
        editMenu.addItem(withTitle: L("撤销"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu; menu.addItem(editItem)
        NSApp.mainMenu = menu
    }
    @objc private func togglePopover() {
        if NSApp.currentEvent?.type == .rightMouseUp { showManager(); return }
        guard !openingPopover else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            openingPopover = true
            // Activating after showing a transient popover can immediately dismiss it.
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.openingPopover = false
                guard let button = self.item.button, button.window != nil else { self.showManager(); return }
                self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                AppDiagnostics.write("popover-open")
            }
        }
    }
    @objc private func openManager() { showManager() }
    @objc private func didWake(_ notification: Notification) { model.refresh(allowingMaintenance: true) }
    private func showManager() {
        guard popover != nil else { managerRequested = true; return }
        popover.performClose(nil)
        // Keep a normal Dock / Cmd-Tab entry while the manager is open. Menu-only
        // mode resumes only after the user explicitly closes the manager window.
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let content = NSHostingController(rootView: MainContent(model: model))
            let w = NSWindow(contentViewController: content)
            w.title = "RouteBar"; w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 980, height: 680)); w.contentMinSize = NSSize(width: 800, height: 520)
            w.isReleasedWhenClosed = false
            w.hidesOnDeactivate = false
            w.collectionBehavior.insert(.moveToActiveSpace)
            w.delegate = self
            w.center(); window = w
        }
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        model.refresh()
        AppDiagnostics.write("manager-open visible=\(window?.isVisible ?? false) dock=regular")
    }
    private func updateStatus() {
        item.button?.title = L(" 路由")
        item.button?.image = NSImage(systemSymbolName: model.needsAttention ? "exclamationmark.triangle" : "point.3.connected.trianglepath.dotted", accessibilityDescription: L("RouteBar 路由检查"))
        item.button?.image?.isTemplate = true
        item.button?.toolTip = L("RouteBar · 蒲公英 {0} · Tailscale {1}", model.pgyLabel, model.tsLabel)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showManager(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        AppDiagnostics.write("manager-close keep-running-in-menu-bar")
        NSApp.setActivationPolicy(.accessory)
    }
    func applicationDidResignActive(_ notification: Notification) {
        AppDiagnostics.write("deactivated manager-visible=\(window?.isVisible ?? false) miniaturized=\(window?.isMiniaturized ?? false)")
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        model?.refresh()
        AppDiagnostics.write("activated manager-visible=\(window?.isVisible ?? false)")
    }
    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if instanceLock != nil { AppDiagnostics.write("normal-termination") }
    }
    func popoverDidClose(_ notification: Notification) { AppDiagnostics.write("popover-close process-kept-running") }
}

if CommandLine.arguments.count == 2 {
    switch CommandLine.arguments[1] {
    case "--check-route-service-build":
        print(RouteService.canAuthorize ? "Route service payload verified" : "Route service payload unavailable")
        exit(RouteService.canAuthorize ? 0 : 1)
    case "--probe-route-service":
        do { try RouteService.probe(); print("Authorized route service responded"); exit(0) }
        catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    default: break
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
