import Foundation
import SystemConfiguration

public final class NetworkEvents {
    private var store: SCDynamicStore?
    public private(set) var available = false
    private let callback: ([String]) -> Void
    public convenience init(callback: @escaping () -> Void) { self.init(keysHandler: { _ in callback() }) }
    public init(keysHandler callback: @escaping ([String]) -> Void) {
        self.callback = callback
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        store = SCDynamicStoreCreate(nil, "HotelWiFi.Events" as CFString, { _, keys, info in
            guard let info else { return }; Unmanaged<NetworkEvents>.fromOpaque(info).takeUnretainedValue().callback(keys as? [String] ?? [])
        }, &context)
        if let store {
            let patterns = ["State:/Network/Interface/.*/Link", "State:/Network/Service/.*/(IPv4|IPv6|DNS|Proxies)",
                            "Setup:/Network/Service/.*", "State:/Network/Global/.*"]
            available = SCDynamicStoreSetNotificationKeys(store, nil, patterns as CFArray) && SCDynamicStoreSetDispatchQueue(store, DispatchQueue.main)
        }
    }
    deinit { if let store { SCDynamicStoreSetDispatchQueue(store, nil) } }
}

/// Event-driven waits with a bounded watchdog; elapsed time never establishes connectivity.
public final class NetworkEventPulse: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var events: NetworkEvents?
    public init() { events = NetworkEvents { [weak self] in self?.signal() } }
    private func signal() {
        let pending = lock.withLock { let p = Array(callbacks.values); callbacks.removeAll(); return p }
        pending.forEach { $0.resume() }
    }
    public func wait(timeout: Double = 1) async {
        let id = UUID()
        await withCheckedContinuation { continuation in
            lock.withLock { callbacks[id] = continuation }
            DispatchQueue.global().asyncAfter(deadline: .now()+timeout) { [weak self] in
                self?.lock.withLock { self?.callbacks.removeValue(forKey: id) }?.resume()
            }
        }
    }
}
