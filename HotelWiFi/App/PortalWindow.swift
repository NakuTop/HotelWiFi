import AppKit
import WebKit
import Network
import HotelWiFiCore

@MainActor final class PortalWindow: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private let message = NSTextField(wrappingLabelWithString: "正在建立 WiFi 认证通道…")
    private var relay: PortalRelay?
    var onClose: (() -> Void)?
    var onVerify: (() -> Void)?
    func show(interface: NWInterface) async throws {
        let relay = PortalRelay(interface: interface); self.relay = relay
        let port = try await relay.start()
        guard self.relay === relay else { relay.stop(); throw HWError.cancelled }
        let config = WKWebViewConfiguration()
        let store = WKWebsiteDataStore.nonPersistent()
        var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!))
        proxy.allowFailover = false
        proxy.applyCredential(username: relay.username, password: relay.password)
        store.proxyConfigurations = [proxy]; config.websiteDataStore = store
        let web = WKWebView(frame: .zero, configuration: config); web.navigationDelegate = self; web.uiDelegate = self
        self.webView = web
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "HotelWiFi · 酒店认证"; window.delegate = self; window.isReleasedWhenClosed = false
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 10; stack.edgeInsets = .init(top: 14, left: 14, bottom: 14, right: 14)
        message.stringValue = "独立 WiFi 登录通道 · 系统代理设置保持原样。请核对酒店名称和网址后填写认证信息。"
        let reload = NSButton(title: "重新加载入口", target: self, action: #selector(reloadPage))
        let verify = NSButton(title: "我已登录，立即复测", target: self, action: #selector(verifyConnection))
        let controls = NSStackView(views: [reload, verify]); controls.spacing = 12
        stack.addArrangedSubview(message); stack.addArrangedSubview(controls); stack.addArrangedSubview(web)
        window.contentView = stack
        for view in [message, controls, web] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
        web.heightAnchor.constraint(greaterThanOrEqualToConstant: 440).isActive = true
        self.window = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        reloadPage()
    }
    @objc private func reloadPage() { webView?.load(URLRequest(url: CaptivePortalProbe.startURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)) }
    @objc private func verifyConnection() { onVerify?() }
    func update(_ text: String) { message.stringValue = text }
    func close() {
        relay?.stop(); relay = nil
        webView?.stopLoading(); webView?.navigationDelegate = nil; webView?.uiDelegate = nil; webView = nil
        window?.delegate = nil; window?.close(); window = nil
    }
    func windowWillClose(_ notification: Notification) { close(); onClose?() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let host = webView.url?.host ?? "酒店认证入口"
        message.stringValue = "当前页面：\(host) · 认证完成后会自动复测；也可点击“我已登录”。"
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        let failure = error as NSError
        message.stringValue = "认证页面未能加载（\(failure.domain) \(failure.code)）。若 VPN 开启了 TUN／强制接管或断网保护，请在 VPN 中临时允许本地网络后重新加载。"
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
              ["http", "https", "about"].contains(scheme), url.user == nil, url.password == nil else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { webView.load(navigationAction.request) }
        return nil
    }
}
