#if canImport(WatchConnectivity) && !os(macOS)
import Foundation
import WatchConnectivity
import os

/// One WCSession wrapper for both platforms. Channel boundaries (per the
/// architecture): `applicationContext` carries the template catalog phone → watch;
/// `transferUserInfo` carries finished workouts watch → phone (queued, survives
/// the phone being dead); `sendMessage` is the live-session debug transport used
/// on simulators where HealthKit mirroring's Rapport link doesn't exist.
public final class ConnectivityHub: NSObject, @unchecked Sendable {
    public static let shared = ConnectivityHub()
    private static let logger = Logger(subsystem: "com.davidruiz.fortiche", category: "connectivity")

    private let lock = NSLock()
    private var _onTemplates: (@Sendable ([TemplateDTO]) -> Void)?
    private var _onFinishedWorkout: (@Sendable (FinishedWorkoutDTO) -> Void)?
    private var _onLiveMessage: (@Sendable (SyncMessage) -> Void)?
    /// Last catalog handed to `pushTemplates` — re-sent once activation
    /// completes (pushes issued before activation would otherwise be lost).
    private var _pendingTemplates: [TemplateDTO]?
    /// Every catalog ever pushed this launch, kept so it can be re-sent when
    /// the watch app gets installed (`sessionWatchStateDidChange`) — a context
    /// sent before the watch app existed is not delivered to it.
    private var _lastTemplates: [TemplateDTO]?

    public var onTemplatesReceived: (@Sendable ([TemplateDTO]) -> Void)? {
        get { lock.withLock { _onTemplates } }
        set { lock.withLock { _onTemplates = newValue } }
    }
    public var onFinishedWorkoutReceived: (@Sendable (FinishedWorkoutDTO) -> Void)? {
        get { lock.withLock { _onFinishedWorkout } }
        set { lock.withLock { _onFinishedWorkout = newValue } }
    }
    /// Live-session messages (simulator debug transport).
    public var onLiveMessage: (@Sendable (SyncMessage) -> Void)? {
        get { lock.withLock { _onLiveMessage } }
        set { lock.withLock { _onLiveMessage = newValue } }
    }
    /// Fires when the counterpart becomes (un)reachable — both sides use it to
    /// resync live state after connection blips.
    public var onReachabilityChange: (@Sendable (Bool) -> Void)? {
        get { lock.withLock { _onReachability } }
        set { lock.withLock { _onReachability = newValue } }
    }
    private var _onReachability: (@Sendable (Bool) -> Void)?

    public func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: Phone → watch: template catalog

    public func pushTemplates(_ templates: [TemplateDTO]) {
        guard WCSession.isSupported() else { return }
        lock.withLock { _lastTemplates = templates }
        guard WCSession.default.activationState == .activated else {
            lock.withLock { _pendingTemplates = templates }
            return
        }
        do {
            let data = try JSONEncoder().encode(templates)
            try WCSession.default.updateApplicationContext(["templates": data])
        } catch {
            Self.logger.error("template push failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Watch → phone: finished workouts

    public func queueFinishedWorkout(_ workout: FinishedWorkoutDTO) {
        guard WCSession.isSupported() else { return }
        guard let data = try? JSONEncoder().encode(workout) else { return }
        WCSession.default.transferUserInfo(["finishedWorkout": data])
    }

    // MARK: Live debug transport

    public func sendLive(_ message: SyncMessage) {
        guard WCSession.isSupported(), WCSession.default.isReachable,
              let data = try? message.encoded() else { return }
        WCSession.default.sendMessage(["live": data], replyHandler: nil) { error in
            Self.logger.info("live send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public var isReachable: Bool {
        WCSession.isSupported() && WCSession.default.isReachable
    }
}

extension ConnectivityHub: WCSessionDelegate {
    public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            Self.logger.error("WC activation failed: \(error.localizedDescription, privacy: .public)")
        } else {
            Self.logger.info("WC activated: \(activationState.rawValue)")
            if let pending = lock.withLock({ let p = _pendingTemplates; _pendingTemplates = nil; return p }) {
                pushTemplates(pending)
            }
            // First activation after install: the counterpart may have set
            // the application context before this app existed. The push
            // callback never fires for that stored copy — read it explicitly
            // or a fresh watch install shows an empty catalog until the
            // phone happens to push again.
            ingest(context: session.receivedApplicationContext)
        }
    }

    public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        ingest(context: applicationContext)
    }

    private func ingest(context: [String: Any]) {
        if let data = context["templates"] as? Data,
           let templates = try? JSONDecoder().decode([TemplateDTO].self, from: data) {
            Self.logger.info("ingesting template catalog (\(templates.count, privacy: .public) templates)")
            onTemplatesReceived?(templates)
        }
    }

    #if os(iOS)
    /// Fires when pairing state or watch-app installation changes. A catalog
    /// pushed before the watch app was installed is never delivered to it —
    /// re-send the moment the app appears.
    public func sessionWatchStateDidChange(_ session: WCSession) {
        guard session.isPaired, session.isWatchAppInstalled,
              let templates = lock.withLock({ _lastTemplates }) else { return }
        Self.logger.info("watch app state changed — re-pushing template catalog")
        pushTemplates(templates)
    }
    #endif

    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let data = userInfo["finishedWorkout"] as? Data,
           let workout = try? JSONDecoder().decode(FinishedWorkoutDTO.self, from: data) {
            onFinishedWorkoutReceived?(workout)
        }
    }

    public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let data = message["live"] as? Data, let decoded = try? SyncMessage.decode(data) {
            onLiveMessage?(decoded)
        }
    }

    public func sessionReachabilityDidChange(_ session: WCSession) {
        onReachabilityChange?(session.isReachable)
    }

    #if os(iOS)
    public func sessionDidBecomeInactive(_ session: WCSession) {}
    public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif
}
#endif
