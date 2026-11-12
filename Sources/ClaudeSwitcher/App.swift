import AppKit
import Darwin
import ServiceManagement
import SwiftUI
import SwitcherCore

/// Launch options (also used to produce UI evidence without touching the real store):
/// `--background` (menu bar only), `--appearance light|dark`,
/// `--ui-fixture <list|switching|success|relogin|error|codex-*|usage|usage-all|usage-empty|usage-loading|usage-stale>`,
/// `--menu-preview` (render the menu content in the window for screenshots), `--lang <code>` (not saved),
/// `--tab usage|claude|codex` (not saved),
/// `--behind` (open the window behind other windows without activating, for screenshots while the Mac is in use).
/// `--snapshot <path.png>` (render the window offscreen at 2x to a PNG and quit; no real window, honors --ui-fixture, --menu-preview, --appearance, --lang),
/// `--snapshot-height <points>` (override the snapshot height; width stays 360 for menus, 700 for windows).
enum LaunchOptions {
    static let args = CommandLine.arguments
    static var background: Bool { args.contains("--background") }
    static var appearance: String? { value("--appearance") }
    static var language: AppLanguage? { value("--lang").flatMap(AppLanguage.matching) }
    static var tab: AppTab? { value("--tab").flatMap(AppTab.init(rawValue:)) }
    static var fixture: String? { value("--ui-fixture") }
    static var menuPreview: Bool { args.contains("--menu-preview") }
    static var behind: Bool { args.contains("--behind") }
    static var snapshot: String? { value("--snapshot") }
    static var snapshotHeight: Double? { value("--snapshot-height").flatMap(Double.init) }

    static func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

/// One model shared by the menu bar extra and the main window.
@MainActor
enum AppModel {
    static let shared: SwitcherModel = {
        // Set before any view or fixture text is produced.
        L10n.language = LaunchOptions.language ?? SwitcherSettings.load(env: .live()).effectiveLanguage
        let model = Fixtures.model(named: LaunchOptions.fixture) ?? SwitcherModel()
        if let forced = LaunchOptions.language { model.previewLanguage(forced) }
        return model
    }()

    /// Visible UI surfaces (menu panel + owned windows). While zero, both status
    /// pollers run at the slow 30 s cadence; showing any surface restores 6 s and
    /// triggers an immediate refresh (audit P3 / A-02).
    private(set) static var visibleSurfaces = 0
    static var anySurfaceVisible: Bool { visibleSurfaces > 0 }

    static func noteSurface(open: Bool) {
        let was = anySurfaceVisible
        visibleSurfaces = max(0, visibleSurfaces + (open ? 1 : -1))
        guard anySurfaceVisible != was else { return }
        shared.scheduleStatusPoll(visible: anySurfaceVisible)
        codex.scheduleStatusPoll(visible: anySurfaceVisible)
        if anySurfaceVisible {
            shared.refreshIfIdle()
            codex.refreshIfIdle()
        }
    }

    /// Demo screens (any `--ui-fixture`) get demo Codex data and never touch the real Codex homes.
    static let codex: CodexModel = {
        _ = shared   // language first
        guard let fixture = LaunchOptions.fixture else { return CodexModel() }
        return Fixtures.codexModel(named: fixture)
    }()

    /// Demo screens (any `--ui-fixture`) get demo usage data and never run the real collectors.
    static let usage: UsageModel = {
        _ = shared   // language first
        guard let fixture = LaunchOptions.fixture else { return UsageModel(settings: shared) }
        return Fixtures.usageModel(named: fixture, settings: shared)
    }()

    /// Demo screens show a fixed tab and never change the remembered one.
    static let tabs = TabSelection(forced: LaunchOptions.tab
        ?? LaunchOptions.fixture.map {
            $0.hasPrefix("usage") ? AppTab.usage : $0.hasPrefix("codex") ? AppTab.codex : AppTab.claude })

    /// Sparkle owner. Inert until the bundle ships a feed URL + public key.
    static let updater = UpdaterModel(isDemo: LaunchOptions.fixture != nil)
}

/// Strings come from a global table rather than view inputs, so the tree is rebuilt when the language changes.
/// Appearance is centralized here too so the main window, the menu popover and sheets all agree:
/// a temporary `--appearance` beats the saved choice, and `system` sets `NSApp.appearance` to nil
/// so an OS light/dark change is followed live instead of a constant captured at launch.
/// Deliberately no `preferredColorScheme` here: a manually hosted SwiftUI tree keeps the last
/// preference after it clears back to nil and then fights the AppKit override — NSAppearance is
/// the single authority.
struct LanguageScoped<Content: View>: View {
    @ObservedObject var model: SwitcherModel
    @ViewBuilder let content: () -> Content

    private var effective: AppAppearance {
        AppAppearance.resolve(override: LaunchOptions.appearance, choice: model.appearanceChoice)
    }

    var body: some View {
        content()
            .id(model.language)
            .onAppear { NSApp.appearance = effective.appKitAppearance }
            .onChange(of: effective) { _, new in NSApp.appearance = new.appKitAppearance }
    }
}

/// AppKit mapping lives on the app side; the core enum stays platform-free.
extension AppAppearance {
    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Owns the main window directly so it opens deterministically at launch (an LSUIElement app otherwise
/// starts with no visible window) and can be reopened from the menu bar.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static private(set) weak var shared: AppDelegate?
    private var detailWindow: NSWindow?
    private var detailID: String?

    /// The single read-only usage detail window: same visible id just focuses;
    /// a new id or reopen after close starts a fresh draft.
    func showUsageDetail(id: String) {
        // same visible id: just focus — an unsaved draft must survive re-click
        if detailWindow?.isVisible == true, detailID == id {
            detailWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        if detailWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = L10n.t(.uiDetails)
            window.isReleasedWhenClosed = false
            window.delegate = self
            detailWindow = window
        }
        detailID = id
        guard let window = detailWindow else { return }
        window.contentViewController = NSHostingController(
            rootView: LanguageScoped(model: AppModel.shared) {
                UsageDetailView(model: AppModel.shared, usage: AppModel.usage,
                                codex: AppModel.codex, id: id,
                                onClose: { [weak self] in self?.detailWindow?.close() })
                // The tree is rebuilt on a language change, so the AppKit title follows it here.
                .onAppear { [weak window] in window?.title = L10n.t(.uiDetails) }
            })
        if window.isVisible != true { AppModel.noteSurface(open: true) }
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    static let apiKeysShouldHideNotification = Notification.Name("usageswitch.apiKeysShouldHide")

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        // Revealed API keys must not outlive their window (audit B-06).
        NotificationCenter.default.post(name: Self.apiKeysShouldHideNotification, object: nil)
        if closing === detailWindow { detailWindow = nil; detailID = nil }
        AppModel.noteSurface(open: false)
        // only OUR two owned windows decide the policy — menus/alerts never count
        let stillOpen = [window, detailWindow].contains {
            $0 !== closing && $0?.isVisible == true
        }
        NSApp.setActivationPolicy(stillOpen ? .regular : .accessory)
    }
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApp.appearance = AppAppearance
            .resolve(override: LaunchOptions.appearance, choice: AppModel.shared.appearanceChoice)
            .appKitAppearance
        if let path = LaunchOptions.snapshot { takeSnapshot(to: path); return }
        AppModel.updater.startIfAllowed()
        if !LaunchOptions.background && !Self.launchedAsLoginItem { showMainWindow() }
    }

    /// Renders the same root view the real window would host, offscreen, and writes it as PNG.
    /// Exists because Screen Recording permission isn't always available for `screencapture`.
    private func takeSnapshot(to path: String) {
        let model = AppModel.shared
        let menuPreview = LaunchOptions.menuPreview
        let content = LanguageScoped(model: model) {
            if menuPreview {
                MenuView(model: model, codex: AppModel.codex, usage: AppModel.usage, tabs: AppModel.tabs)
            } else {
                MainView(model: model, codex: AppModel.codex, usage: AppModel.usage, tabs: AppModel.tabs)
            }
        }
        let base = menuPreview ? CGSize(width: 360, height: 600) : CGSize(width: 700, height: 760)
        let size = LaunchOptions.snapshotHeight.map { CGSize(width: base.width, height: $0) } ?? base
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        if let appKit = AppAppearance
            .resolve(override: LaunchOptions.appearance, choice: model.appearanceChoice)
            .appKitAppearance { window.appearance = appKit }
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        if menuPreview { hosting.frame.size = hosting.fittingSize }
        window.orderBack(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(hosting.bounds.width) * 2,
                                   pixelsHigh: Int(hosting.bounds.height) * 2,
                                   bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .calibratedRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = hosting.bounds.size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        NSApp.terminate(nil)
    }

    /// Opened at login: stay in the menu bar instead of showing the window. The Apple event flag is the classic
    /// signal; since it isn't guaranteed for SMAppService launches, the first launch of a registered login item
    /// within two minutes of this user's console login also counts (once per login, so a manual reopen shows it).
    private static var launchedAsLoginItem: Bool {
        let defaults = UserDefaults.standard
        let login = consoleLoginDate()
        let alreadyUsed = login.map { defaults.double(forKey: lastLoginLaunchKey) == $0.timeIntervalSince1970 } ?? false
        let byEvent = NSAppleEventManager.shared().currentAppleEvent.map {
            $0.eventID == kAEOpenApplication
                && $0.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        } ?? false
        let enabledAt = defaults.double(forKey: SwitcherModel.launchAtLoginEnabledAtKey)
        let byTiming = login.map {
            SMAppService.mainApp.status == .enabled && enabledAt < $0.timeIntervalSince1970
                && Date().timeIntervalSince($0) < loginLaunchWindow
        } ?? false
        guard byEvent || (byTiming && !alreadyUsed) else { return false }
        // One background start per login: a later manual open in the same session always shows the window.
        if let login { defaults.set(login.timeIntervalSince1970, forKey: lastLoginLaunchKey) }
        return true
    }

    private static let loginLaunchWindow: TimeInterval = 120
    private static let lastLoginLaunchKey = "lastLoginItemLaunch"

    /// Start of this user's current console (GUI) session, from utmpx.
    private static func consoleLoginDate() -> Date? {
        setutxent()
        defer { endutxent() }
        var newest: Date?
        while let entry = getutxent() {
            guard entry.pointee.ut_type == USER_PROCESS else { continue }
            let line = withUnsafeBytes(of: entry.pointee.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let user = withUnsafeBytes(of: entry.pointee.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard line == "console", user == NSUserName() else { continue }
            let started = Date(timeIntervalSince1970: TimeInterval(entry.pointee.ut_tv.tv_sec))
            if newest.map({ started > $0 }) ?? true { newest = started }
        }
        return newest
    }

    /// `<scheme>://switch?id=<account-id>[&force=1]` runs the same UI action as the Switch button.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == ProductInfo.urlScheme && url.host == "switch" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let id = items.first(where: { $0.name == "id" })?.value else { continue }
            showMainWindow()
            AppModel.shared.requestSwitch(id: id, force: items.contains { $0.name == "force" && $0.value == "1" })
        }
    }

    /// Quitting mid-switch would skip the relauncher restore and could leave files mid-swap, and quitting during
    /// another Codex action could leave it half done, so both wait for the user. A Codex sign-in is simply cancelled
    /// (its `codex login` ends) before the app quits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let codex = AppModel.codex
        if AppModel.shared.isBusy {
            AppModel.shared.banner = .init(kind: .info, text: L10n.t(.uiBusyQuit))
        } else if codex.isBusy && !codex.isSigningIn && !codex.isDemo {
            codex.banner = .init(kind: .info, text: L10n.t(.codexBusyQuit))
            AppModel.tabs.tab = .codex
        } else {
            codex.stopForQuit()
            AppModel.usage.stopForQuit()
            return .terminateNow
        }
        showMainWindow()
        return .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func showMainWindow() {
        if window == nil {
            let model = AppModel.shared
            let content = LanguageScoped(model: model) {
                if LaunchOptions.menuPreview {
                    MenuView(model: model, codex: AppModel.codex, usage: AppModel.usage, tabs: AppModel.tabs)
                } else {
                    MainView(model: model, codex: AppModel.codex, usage: AppModel.usage, tabs: AppModel.tabs)
                }
            }
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = ProductInfo.name
            w.contentViewController = NSHostingController(rootView: content)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setFrameAutosaveName("ClaudeSwitcherMain")
            if !w.setFrameUsingName("ClaudeSwitcherMain") { w.center() }
            window = w
        }
        if LaunchOptions.behind {
            window?.orderBack(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        if window?.isVisible != true { AppModel.noteSurface(open: true) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

}

struct ClaudeSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @StateObject private var codex = AppModel.codex
    @StateObject private var usage = AppModel.usage
    @StateObject private var tabs = AppModel.tabs

    /// The usage title when the setting is on and a fresh window exists; else the account name.
    private var barTitle: String? {
        if model.menuBarShowsUsage, let title = usage.menuBarTitle { return title }
        return model.menuBarTitle
    }

    var body: some Scene {
        MenuBarExtra {
            LanguageScoped(model: model) { MenuView(model: model, codex: codex, usage: usage, tabs: tabs) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.isBusy ? "arrow.triangle.2.circlepath" : "person.2.circle")
                // No TimelineView here: inside a MenuBarExtra label it re-rendered the status
                // button image without end (2.2.0 pegged a core and grew memory at launch).
                if let title = barTitle { Text(title) }
            }
            .accessibilityLabel(barTitle.map { "\(ProductInfo.name), \($0)" } ?? ProductInfo.name)
        }
        .menuBarExtraStyle(.window)
    }
}
