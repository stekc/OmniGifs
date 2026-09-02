import AppKit
import OSLog
import WebKit

@MainActor
final class DiscordSessionCoordinator: NSObject {
    enum State: Equatable {
        case notConnected
        case connecting
        case connected
        case expired
        case offline
    }

    static let shared = DiscordSessionCoordinator()
    private static let logger = Logger(subsystem: "win.stkc.omnigifs", category: "DiscordSession")

    private(set) var state: State = .notConnected {
        didSet { if oldValue != state { onStateChange?(state) } }
    }
    var onStateChange: ((State) -> Void)?

    private var webView: WKWebView?
    private var loginWindow: NSWindow?
    private var loginCompletionMonitor: Task<Void, Never>?
    private var loginRefreshTask: Task<Void, Never>?
    private var navigationWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    private override init() {
        super.init()
    }

    private func browser() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        // The default data store keeps Discord's cookies on disk even when the
        // expensive hidden browser and its WebContent process are released.
        configuration.websiteDataStore = .default()
        configuration.preferences.isElementFullscreenEnabled = false
        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.navigationDelegate = self
        webView = browser
        return browser
    }

    func showLoginWindow() {
        let webView = browser()
        let window: NSWindow
        if let loginWindow {
            window = loginWindow
        } else {
            let controller = NSViewController()
            controller.view = webView
            window = NSWindow(contentViewController: controller)
            window.title = "Log In to Discord"
            window.setContentSize(NSSize(width: 1040, height: 760))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.center()
            window.isReleasedWhenClosed = false
            loginWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        state = .connecting
        monitorVisibleLoginCompletion()

        if webView.url == nil || isLoginURL(webView.url) {
            webView.load(URLRequest(url: URL(string: "https://discord.com/login")!))
        }
    }

    func logOut() async {
        loginCompletionMonitor?.cancel()
        loginCompletionMonitor = nil
        loginRefreshTask?.cancel()
        loginRefreshTask = nil
        loginWindow?.orderOut(nil)
        releaseHiddenBrowser()

        let store = WKWebsiteDataStore.default()
        let records = await withCheckedContinuation { continuation in
            store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) {
                continuation.resume(returning: $0)
            }
        }
        let discordRecords = records.filter {
            $0.displayName.lowercased().contains("discord")
        }
        if !discordRecords.isEmpty {
            await withCheckedContinuation { continuation in
                store.removeData(
                    ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                    for: discordRecords
                ) {
                    continuation.resume()
                }
            }
        }
        state = .notConnected
    }

    func refreshFavorites(
        forceReload: Bool = false,
        reportConnecting: Bool = true
    ) async -> Data? {
        let webView = browser()
        if reportConnecting { state = .connecting }

        if forceReload || webView.url == nil {
            webView.load(URLRequest(url: URL(string: "https://discord.com/app")!))
            await waitForNavigation()
        } else if webView.isLoading {
            await waitForNavigation()
        }

        if isLoginURL(webView.url) {
            state = .expired
            releaseHiddenBrowser()
            return nil
        }

        for attempt in 0..<8 {
            do {
                if let json = try await extractFavoritesJSON(),
                    let data = json.data(using: .utf8),
                    (try? GIFImporter.decodeSnapshot(data)) != nil
                {
                    state = .connected
                    if loginWindow?.isVisible == true { loginWindow?.orderOut(nil) }
                    releaseHiddenBrowser()
                    return data
                }
            } catch {
                Self.logger.error(
                    "Favorites extraction failed: \(error.localizedDescription, privacy: .public)")
                if isLoginURL(webView.url) {
                    state = .expired
                    releaseHiddenBrowser()
                    return nil
                }
            }

            if attempt < 7 {
                try? await Task.sleep(for: .milliseconds(350))
            }
        }

        state = isLoginURL(webView.url) ? .expired : .offline
        releaseHiddenBrowser()
        return nil
    }

    private func releaseHiddenBrowser() {
        guard loginWindow?.isVisible != true, let webView else { return }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
        loginWindow?.contentViewController = nil
        loginWindow = nil
        self.webView = nil
    }

    private func monitorVisibleLoginCompletion() {
        loginCompletionMonitor?.cancel()
        loginCompletionMonitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.loginWindow?.isVisible == true else { return }
                if let url = self.webView?.url, Self.isAuthenticatedAppURL(url) {
                    self.completeVisibleLogin()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func completeVisibleLogin() {
        guard loginWindow?.isVisible == true, loginRefreshTask == nil else { return }
        loginCompletionMonitor?.cancel()
        loginCompletionMonitor = nil
        loginWindow?.orderOut(nil)
        loginRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.refreshFavorites()
            self.loginRefreshTask = nil
        }
    }

    private func waitForNavigation() async {
        guard webView?.isLoading == true else { return }
        let id = UUID()
        await withCheckedContinuation { continuation in
            navigationWaiters[id] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                self?.resumeNavigationWaiter(id)
            }
        }
    }

    private func resumeNavigationWaiters() {
        let waiters = navigationWaiters.values
        navigationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func resumeNavigationWaiter(_ id: UUID) {
        navigationWaiters.removeValue(forKey: id)?.resume()
    }

    private func extractFavoritesJSON() async throws -> String? {
        guard let webView else { return nil }
        let script = #"""
            try {
              window.__omniGifsFrecencyStore ??= webpackChunkdiscord_app.push([
                [Symbol()],
                ,
                req => {
                  if (!req?.c) return null;
                  const exports = Object.values(req.c)
                    .map(module => module.exports)
                    .filter(value => value && typeof value === "object" && value !== window)
                    .flatMap(value => [value, ...Object.values(value)]);
                  return exports.find(value =>
                    value?.ProtoClass?.typeName?.endsWith(".FrecencyUserSettings")
                  ) ?? null;
                }
              ]);
              const store = window.__omniGifsFrecencyStore;
              if (!store) return null;

              // A newly loaded Discord page initially exposes its persisted local
              // settings. The asynchronous load replaces that snapshot with the
              // account's current settings, so reading before it resolves can
              // resurrect removed favorites or omit newly added ones.
              const load = store.loadIfNecessary?.();
              if (load && typeof load.then === "function") await load;

              const value = store.getCurrentValue?.();
              if (!value) return null;
              return JSON.stringify(value.favoriteGifs?.gifs ?? {});
            } catch (_) {
              return null;
            }
            """#
        return try await webView.callAsyncJavaScript(
            script,
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? String
    }

    private func isLoginURL(_ url: URL?) -> Bool {
        guard let url, Self.isTrustedDiscordURL(url) else { return false }
        return url.path == "/login" || url.path == "/register"
    }

    static func isTrustedDiscordURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
            let host = url.host?.lowercased()
        else { return false }
        return host == "discord.com" || host.hasSuffix(".discord.com")
    }

    static func isAuthenticatedAppURL(_ url: URL) -> Bool {
        guard isTrustedDiscordURL(url),
            let host = url.host?.lowercased(),
            ["discord.com", "www.discord.com", "canary.discord.com", "ptb.discord.com"]
                .contains(host)
        else { return false }
        return url.path == "/app" || url.path == "/channels/@me"
            || url.path.hasPrefix("/channels/")
    }
}

extension DiscordSessionCoordinator: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resumeNavigationWaiters()
        if isLoginURL(webView.url) {
            state = .expired
        } else if loginWindow?.isVisible == true,
            webView.url.map(Self.isAuthenticatedAppURL) == true
        {
            // A visible login flow has just completed. Normal hidden loads are
            // already awaited by refreshFavorites and must not start a duplicate.
            completeVisibleLogin()
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        resumeNavigationWaiters()
        state = .offline
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        resumeNavigationWaiters()
        state = .offline
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if Self.isTrustedDiscordURL(url) { return .allow }

        let isTopLevel = navigationAction.targetFrame?.isMainFrame != false
        guard isTopLevel else { return .allow }
        if navigationAction.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }
}
