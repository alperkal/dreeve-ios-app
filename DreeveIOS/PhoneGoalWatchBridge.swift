import Foundation
import Combine
import WatchConnectivity

@MainActor
final class PhoneGoalWatchBridge: NSObject, ObservableObject, WCSessionDelegate {
    private let storage = GoalWatchStorage(directory: URL.applicationSupportDirectory.appendingPathComponent("WatchOutbound", isDirectory: true))
    // Keep priority delivery state separate from the outbox: publishing before
    // activation must not consume the update that should wake the complication.
    private let priorityStorage = GoalWatchStorage(directory: URL.applicationSupportDirectory.appendingPathComponent("WatchOutbound/Priority", isDirectory: true))
    private var latest: GoalWatchEnvelope?
    private var started = false

    override init() { super.init(); latest = storage.envelope() }
    func start() {
        guard WCSession.isSupported() else { return }
        if !started { started = true; WCSession.default.delegate = self; WCSession.default.activate() }
        else if WCSession.default.activationState == .notActivated { WCSession.default.activate() }
        else { sendLatest() }
    }
    func selectInstance(_ instance: String?) {
        if instance == nil || latest?.snapshot.instanceID != instance { publish(.empty) }
    }
    func publish(_ snapshot: GoalWidgetSnapshot) {
        let retained = snapshot.retainingKnownProgress(from: latest?.snapshot)
        guard latest?.snapshot != retained else { sendLatest(); return }
        let sender = latest?.senderID ?? UUID().uuidString
        let envelope = GoalWatchEnvelope(version: 1, senderID: sender, revision: (latest?.revision ?? 0) + 1,
            sentAt: max(Date.now, latest?.sentAt.addingTimeInterval(0.001) ?? .distantPast), snapshot: retained)
        do {
            try storage.write(envelope)
            latest = envelope
            sendLatest()
        } catch { /* Keep the previous valid envelope; retry on the next publication. */ }
    }
    private func payload() -> [String: Any] {
        (try? latest?.contextPayload()) ?? [:]
    }
    private func sendLatest() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled, latest != nil else { return }
        let context = payload()
        guard !context.isEmpty else { return }
        // A context error must not discard an independently eligible priority send.
        try? session.updateApplicationContext(context)
        if context["goalFilePending"] != nil { queueFile() }
        if let latest, latest.changesVisibleGoals(from: priorityStorage.envelope()),
           session.isComplicationEnabled, session.remainingComplicationUserInfoTransfers > 0 {
            session.transferCurrentComplicationUserInfo(context)
            try? priorityStorage.write(latest)
        }
    }
    private func queueFile() {
        guard let latest else { return }
        let session = WCSession.default
        if session.outstandingFileTransfers.contains(where: {
            $0.file.metadata?["revision"] as? Int == latest.revision && $0.file.metadata?["senderID"] as? String == latest.senderID
        }) { return }
        // Each transfer gets an immutable file; later publications cannot overwrite it.
        do {
            let folder = URL.applicationSupportDirectory.appendingPathComponent("WatchOutbound/Transfers", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(UUID().uuidString + ".json")
            try JSONEncoder().encode(latest).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var excluded = file; var flags = URLResourceValues(); flags.isExcludedFromBackup = true; try excluded.setResourceValues(flags)
            session.transferFile(file, metadata: ["revision": latest.revision, "senderID": latest.senderID])
        } catch {}
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.sendLatest() }
    }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) { Task { @MainActor in self.sendLatest() } }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard message["requestGoals"] as? Bool == true else { replyHandler([:]); return }
        Task { @MainActor in
            self.sendLatest()
            replyHandler(self.payload())
        }
    }
    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        guard error != nil else { return }
        let payload = userInfoTransfer.userInfo
        Task { @MainActor in
            // Re-arm a failed priority transfer, without clearing a newer send.
            if let queued = self.priorityStorage.envelope(), queued.matches(payload: payload) {
                try? self.priorityStorage.remove()
            }
        }
    }
    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        // A later publication/activation can retry if delivery failed.
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
    }
}
