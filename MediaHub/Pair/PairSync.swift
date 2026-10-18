import Foundation
import Observation
import UIKit

/// Keeps this device and its Pear.pair account in step (cloud/CLOUD_API.md §2.2 and §4). Port of the Kotlin SyncEngine.
///
/// There is no outbox. The snapshot in PairStore holds what the server last agreed with, and a local change is whatever
/// differs from it when a push runs. An offline edit therefore survives a restart, because the snapshot was never updated for it.
/// Everything runs on the main actor, as the stores it reads and writes do.
@MainActor @Observable
final class PairSync {
    static let shared = PairSync()

    /// Posted after a pull changed local data, so the screens re-read their stores.
    static let remoteApplied = Notification.Name("PairSync.remoteApplied")

    /// Posted after a pull or a replace changed shared settings. The keys are in userInfo["keys"] as a Set<String>.
    static let settingsApplied = Notification.Name("PairSync.settingsApplied")

    /// Whether Simkl is connected. The app sets it at start. A Simkl library is not synced.
    var simklConnected: () -> Bool = { false }

    /// Writes the watch seconds not yet on disk into the stored log, so a merge reads them. The app sets it at start.
    var flushWatchLog: () -> Void = {}
    /// Called after a pull or a replace wrote the stored watch log, so the live log reads it again. The app sets it at start.
    var watchLogStored: () -> Void = {}

    private(set) var state = PairSyncState()

    private let store = PairStore()
    private let client = PairClient()

    /// Scopes that changed on this device since the last push.
    private var dirty = Set<SyncScope>()
    /// Progress tokens that must go out now (a pause, a close).
    private var forced = Set<String>()
    /// Progress tokens due for the 60-second cadence.
    private var due = Set<String>()
    private var lastProgressPush: [String: Double] = [:]
    /// When each profile's watch log last went out. The throttle is per profile (see pushScopes).
    private var lastWatchLogPush: [String: Double] = [:]

    private var timersRunning = false
    private var pushScheduled = false
    private var cycleRunning = false
    private var cycleAgain = false
    private var pendingReplace = false
    /// True only while a replace pull runs: the default profile the device synthesizes must not be kept.
    private var replacing = false
    /// Set when the settings switch goes on: the next full pull starts from the beginning, so the account's settings come in.
    private var rePullSettings = false
    /// Unix ms of the last push, for the one-push-per-15-seconds rule.
    private var lastPushAt: Double = 0
    /// When the last full sync finished without error, and how many full cycles have ended (any outcome). See `freshen`.
    private var lastFullSyncAt: Date?
    private var fullCyclesEnded = 0
    /// Running time the system grants while a sync is in flight and the app has just left the screen.
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var retrySeconds = SyncRules.retryMinSeconds
    private var retryGen = 0
    /// The shared settings as they were at the last check, to tell a real change from an unrelated defaults write.
    @ObservationIgnored private var lastSettingsFingerprint: String?
    /// The defaults-change observer, installed once.
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?

    private struct Pending {
        let key: String
        let change: [String: Any]
        let updatedAt: Double
        let fingerprint: String?
    }

    private struct PushOutcome {
        let sent: Int
        let refused: String?
    }

    var isSignedIn: Bool { store.isSignedIn }

    /// Whether this device syncs the shared settings (SyncedSettings). Off until the person turns it on, on this device.
    var syncSettingsOn: Bool { UserDefaults.standard.bool(forKey: Self.settingsFlagKey) }
    static let settingsFlagKey = "pair.syncSettings"

    // MARK: Calls from the app

    /// Start-up: starts the timers and a first sync, when an account is signed in here. Does nothing otherwise.
    func startIfSignedIn() {
        guard store.isSignedIn else { return }
        ensureRunning()
        if syncSettingsOn { lastSettingsFingerprint = settingsFingerprint() }
        syncNow()
    }

    /// Syncs now: pushes what changed here, then pulls what changed elsewhere.
    func syncNow() { run(full: true) }

    /// The app came to the foreground.
    func foreground() { syncNow() }

    /// Brings this device up to date before a title opens, so its resume point is the account's and not an older one from
    /// here. Waits at most `timeout` seconds: offline or slow, it gives up and the title opens with what is on the device.
    /// The sync carries on by itself. Does nothing without an account, while paused, or right after a full sync.
    func freshen(timeout: Double = 2.5) async {
        guard store.isSignedIn else { return }
        if let until = state.pausedUntil, Date.now < until { return }
        if let last = lastFullSyncAt, Date.now.timeIntervalSince(last) < 20 { return }
        let before = fullCyclesEnded
        if cycleRunning { cycleAgain = true } else { run(full: true) }
        let deadline = Date.now.addingTimeInterval(timeout)
        while fullCyclesEnded == before, Date.now < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// The "Sync settings" switch was set. On: the next full pull starts from the beginning, so the account's settings come
    /// in, and a sync runs now. Off: no shared setting is sent or applied from here on.
    func setSyncSettings(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.settingsFlagKey)
        if on { rePullSettings = true }
        guard store.isSignedIn else { return }
        lastSettingsFingerprint = on ? settingsFingerprint() : nil
        syncNow()
    }

    /// Local data of `kinds` changed for `profile`. Pushed soon. The profile list is global, so its scope has no profile.
    func localChanged(_ kinds: [SyncKind], profile: String = ProfileKeys.activeID) {
        guard store.isSignedIn else { return }
        for kind in kinds {
            dirty.insert(SyncScope(profile: kind == .profile ? "" : profile, kind: kind))
        }
        requestPush()
    }

    /// A playback save for `titleID` in the active profile. `immediate` (a pause or a close) pushes at once; otherwise the
    /// 60-second cadence applies.
    func progressSaved(titleID: String, immediate: Bool) {
        guard store.isSignedIn else { return }
        let profile = ProfileKeys.activeID
        let token = RecordKey.token(profile, titleID)
        dirty.insert(SyncScope(profile: profile, kind: .progress))
        if immediate {
            forced.insert(token)
            run(full: false)
        } else {
            let last = lastProgressPush[token] ?? 0
            if Date().unixMs - last >= SyncRules.progressEveryMs { due.insert(token) }
            requestPush()
        }
    }

    // MARK: Account calls (the settings screen)

    /// Makes an account and signs this device in. The recovery key is shown once: the caller shows it, then calls
    /// `finishSignIn`.
    func createAccount(deviceName: String) async throws -> (accountID: String, recoveryKey: String) {
        let made = try await client.createAccount(deviceName: Self.cleanDeviceName(deviceName), platform: Self.platform)
        store.save(made.credentials)
        return (made.credentials.accountID, made.recoveryKey)
    }

    /// Joins an account with a pair code from a device that is signed in. The caller then asks what to do with local data
    /// and calls `finishSignIn`.
    func joinWithCode(_ code: String, deviceName: String) async throws {
        let credentials = try await client.redeem(
            code: Self.cleanCode(code), deviceName: Self.cleanDeviceName(deviceName), platform: Self.platform)
        store.save(credentials)
    }

    /// Joins an account with its ID and recovery key. The caller then asks what to do with local data and calls `finishSignIn`.
    func joinWithRecoveryKey(accountID: String, recoveryKey: String, deviceName: String) async throws {
        let credentials = try await client.recover(
            accountID: accountID.trimmingCharacters(in: .whitespacesAndNewlines),
            recoveryKey: recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines),
            deviceName: Self.cleanDeviceName(deviceName), platform: Self.platform)
        store.save(credentials)
    }

    /// The device is in the account: starts the sync. `replaceLocal` discards this device's synced data and takes the account's.
    func finishSignIn(replaceLocal: Bool) {
        ensureRunning()
        pendingReplace = replaceLocal
        run(full: true)
    }

    /// A pair code for another device. Valid for five minutes, and once.
    func makePairCode() async throws -> (code: String, expiresAt: Date) {
        guard let credentials = store.credentials else { throw CloudError.rejected(status: 401, code: "unauthorized", message: "This device isn't signed in.") }
        let made = try await client.makeCode(bearer: credentials.bearer)
        return (made.code, Date(timeIntervalSince1970: made.expiresAt / 1000))
    }

    func devices() async throws -> [PairDevice] {
        guard let credentials = store.credentials else { return [] }
        return try await client.devices(bearer: credentials.bearer)
    }

    func revokeDevice(id: String) async throws {
        guard let credentials = store.credentials else { return }
        try await client.revokeDevice(bearer: credentials.bearer, id: id)
    }

    /// Signs this device out. Its token is revoked on the server when that works. The local data stays on the device.
    /// Returns false when the server could not be told; the device is signed out here either way.
    func signOut() async -> Bool {
        var revoked = true
        if let credentials = store.credentials {
            do {
                try await client.revokeDevice(bearer: credentials.bearer, id: credentials.deviceID)
            } catch {
                revoked = false
            }
        }
        forgetHere()
        return revoked
    }

    /// Deletes the account on the server, then forgets it here. The local data stays.
    func deleteAccount() async throws {
        guard let credentials = store.credentials else { return }
        try await client.deleteAccount(bearer: credentials.bearer)
        forgetHere()
    }

    private func forgetHere() {
        store.forget()
        dirty.removeAll()
        forced.removeAll()
        due.removeAll()
        retryGen += 1
        lastSettingsFingerprint = nil
        state = PairSyncState()
    }

    static let platform = "iOS"

    /// A device name the server takes: trimmed and at most 64 characters, never empty.
    static func cleanDeviceName(_ raw: String) -> String {
        let trimmed = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        return trimmed.isEmpty ? "iPhone" : trimmed
    }

    /// A pair code as the server takes it: upper case, without spaces and dashes.
    static func cleanCode(_ raw: String) -> String {
        raw.uppercased().filter { !$0.isWhitespace && $0 != "-" }
    }

    // MARK: Timers and triggers

    private func ensureRunning() {
        guard !timersRunning else { return }
        timersRunning = true
        // The settings screens write their values straight to UserDefaults, so a defaults write is the signal to look.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.settingsMayHaveChanged() }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(SyncRules.pullEverySeconds * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                await self.cycle(full: true)
            }
        }
    }

    /// A defaults write happened. When a shared setting changed, its scopes are marked dirty and a push is scheduled. The
    /// fingerprint check stops the feedback loop: this device's own writes (the last-sync time, the cursor) change no
    /// shared setting, so they mark nothing.
    private func settingsMayHaveChanged() {
        guard store.isSignedIn, syncSettingsOn else { return }
        let now = settingsFingerprint()
        guard let before = lastSettingsFingerprint else {
            lastSettingsFingerprint = now
            return
        }
        guard now != before else { return }
        lastSettingsFingerprint = now
        dirty.insert(SyncScope(profile: SyncRules.accountScope, kind: .settings))
        for profile in LocalStore.profiles().list {
            dirty.insert(SyncScope(profile: profile.id, kind: .settings))
        }
        requestPush()
    }

    /// The shared settings this device holds, for the account scope and every profile, as one string. Equal strings mean
    /// that no shared setting changed.
    private func settingsFingerprint() -> String {
        let snapshot = store.readSnapshot()
        var parts: [String] = []
        let scopes = [SyncRules.accountScope] + LocalStore.profiles().list.map(\.id)
        for scope in scopes {
            let records = SyncedSettings.localRecords(profile: scope, hasSnapshotEntry: { snapshot[$0] != nil })
            for (key, record) in records.sorted(by: { $0.key < $1.key }) {
                parts.append(key + RecordKey.sep + record.fingerprint)
            }
        }
        return parts.joined(separator: "\n")
    }

    private func run(full: Bool) {
        Task { await cycle(full: full) }
    }

    private func requestPush() {
        guard !pushScheduled, store.isSignedIn else { return }
        pushScheduled = true
        Task {
            try? await Task.sleep(nanoseconds: UInt64(SyncRules.debounceSeconds * 1_000_000_000))
            let wait = lastPushAt + SyncRules.minPushGapSeconds * 1000 - Date().unixMs
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000)) }
            pushScheduled = false
            await cycle(full: false)
        }
    }

    private func retryIn(seconds: Double) {
        retryGen += 1
        let generation = retryGen
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 1) * 1_000_000_000))
            if generation == retryGen { await cycle(full: true) }
        }
    }

    // MARK: One cycle

    /// One pass. `full` covers every scope and pulls; otherwise only the dirty scopes are pushed. A replace (asked for, or
    /// pending) wipes this device's synced data first and takes the account's: the pull runs before the push, so local
    /// leftovers are not sent.
    private func cycle(full: Bool, replaceLocal: Bool = false) async {
        guard let credentials = store.credentials else { return }
        if cycleRunning {
            cycleAgain = true
            return
        }
        if let until = state.pausedUntil, Date.now < until { return }

        let replace = replaceLocal || pendingReplace
        pendingReplace = false
        cycleRunning = true
        let taken = dirty
        dirty.removeAll()
        if full { state.syncing = true }

        beginBackgroundTime()
        await perform(full: full, replace: replace, taken: taken, bearer: credentials.bearer)
        endBackgroundTime()
        if full { fullCyclesEnded += 1 }

        cycleRunning = false
        if cycleAgain {
            cycleAgain = false
            await cycle(full: true)
        }
    }

    private func perform(full: Bool, replace: Bool, taken: Set<SyncScope>, bearer: String) async {
        do {
            var changed = false
            let outcome: PushOutcome
            if replace {
                wipeLocalSyncData()
                store.lastServerTs = 0
                rePullSettings = false
                replacing = true
                defer { replacing = false }
                changed = try await pullAll(bearer: bearer)
                replacing = false
                // The lists were just rebuilt from the account, so progress keeps its cadence here.
                outcome = try await pushScopes(bearer: bearer, targets: allScopes(), allProgress: false)
            } else if full {
                // A full sync sends every progress that differs from the account, whatever the cadence marks say.
                outcome = try await pushScopes(bearer: bearer, targets: allScopes(), allProgress: true)
                // The settings switch went on: pull from the start, so the account's settings come in (the cursor may be past them).
                if rePullSettings { store.lastServerTs = 0 }
                changed = try await pullAll(bearer: bearer)
                rePullSettings = false
            } else {
                outcome = try await pushScopes(bearer: bearer, targets: taken, allProgress: false)
            }

            // A replace wipes local data even when the account sends nothing back, so the screens must re-read.
            if changed || replace { NotificationCenter.default.post(name: Self.remoteApplied, object: nil) }
            retrySeconds = SyncRules.retryMinSeconds
            if full || outcome.sent > 0 { store.lastSyncAt = Date.now }
            if full { lastFullSyncAt = Date.now }
            state.syncing = false
            state.pausedUntil = nil
            state.error = outcome.refused.map { "Some changes were refused by the server (\($0))." }
            state.lastSyncAt = store.lastSyncAt
        } catch is CancellationError {
            dirty.formUnion(taken)
            state.syncing = false
        } catch let error as CloudError {
            dirty.formUnion(taken)
            onFailure(error)
        } catch {
            dirty.formUnion(taken)
            state.syncing = false
            state.error = "Sync failed. It will try again."
            retryIn(seconds: retrySeconds)
        }
    }

    private func onFailure(_ error: CloudError) {
        switch error {
        case .quota:
            // Free-plan cap used up: stop, keep the outbox, resume at 00:00 UTC. Never a retry loop.
            let until = nextUTCMidnight()
            state.syncing = false
            state.pausedUntil = until
            state.error = "Sync paused, will resume."
            retryIn(seconds: until.timeIntervalSinceNow)
        case .rejected(_, let code, _) where code == "unauthorized":
            store.forget()
            retryGen += 1
            state = PairSyncState(error: "This device was signed out of Pear.pair. Pair it again to sync.",
                                  needsSignIn: true)
        case .rejected(let status, _, let message) where status < 500:
            state.syncing = false
            state.error = message
        default:
            // Network trouble, a bad answer, or a 5xx: back off, then try again.
            state.syncing = false
            if case .network = error {
                state.error = "No connection to Pear.pair. It will try again."
            } else {
                state.error = "Pear.pair had a problem. It will try again."
            }
            retryIn(seconds: retrySeconds)
            retrySeconds = min(retrySeconds * 2, SyncRules.retryMaxSeconds)
        }
    }

    /// A push that starts as the app leaves the screen gets time to finish. Ended when the cycle ends or the system asks.
    private func beginBackgroundTime() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "pear.pair.sync") { [weak self] in
            self?.endBackgroundTime()
        }
    }

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func nextUTCMidnight() -> Date {
        let day = 86_400_000.0
        return Date(timeIntervalSince1970: ((floor(Date().unixMs / day) + 1) * day) / 1000)
    }

    // MARK: Push

    /// Every scope this device has, or had (a snapshot record whose profile was deleted still needs its tombstone).
    private func allScopes() -> Set<SyncScope> {
        var out: Set<SyncScope> = [SyncScope(profile: "", kind: .profile)]
        let settingsOn = syncSettingsOn
        for profile in LocalStore.profiles().list {
            out.insert(SyncScope(profile: profile.id, kind: .history))
            out.insert(SyncScope(profile: profile.id, kind: .progress))
            out.insert(SyncScope(profile: profile.id, kind: .watchlog))
            if syncsLibrary(profile.id) { out.insert(SyncScope(profile: profile.id, kind: .library)) }
            if settingsOn { out.insert(SyncScope(profile: profile.id, kind: .settings)) }
        }
        if settingsOn { out.insert(SyncScope(profile: SyncRules.accountScope, kind: .settings)) }
        for composite in store.readSnapshot().keys {
            guard let parts = RecordKey.parse(composite) else { continue }
            // With the switch off, a settings record of the snapshot gets no scope: nothing is sent for it.
            if parts.kind == .settings && !settingsOn { continue }
            out.insert(SyncScope(profile: parts.kind == .profile ? "" : parts.profile, kind: parts.kind))
        }
        return out
    }

    /// Pushes what differs from the snapshot in `targets`, in batches of SyncRules.pushBatch.
    private func pushScopes(bearer: String, targets: Set<SyncScope>, allProgress: Bool) async throws -> PushOutcome {
        let now = Date().unixMs
        var snapshot = store.readSnapshot()
        var pending: [Pending] = []

        for target in targets {
            let local = localRecords(target)
            // A profile's watch log goes out at most once per window. Decided once per profile, so every changed month of
            // the profile goes out together, and the window is recorded only when something was queued.
            let dueNow = now - (lastWatchLogPush[target.profile] ?? 0) >= SyncRules.watchLogEveryMs
            var queuedWatchLog = false
            for (key, record) in local.records {
                let old = snapshot[key]
                if old?.fingerprint == record.fingerprint { continue }
                if record.kind == .progress && !progressMayPush(record, old: old, now: now, allProgress: allProgress) { continue }
                if record.kind == .watchlog {
                    if !dueNow { continue }
                    queuedWatchLog = true
                }
                let updatedAt = stamp(record.intrinsicAt, old: old, now: now)
                pending.append(Pending(
                    key: key,
                    change: changeObject(profile: record.profile, kind: record.kind, key: record.key,
                                         updatedAt: updatedAt, data: record.body),
                    updatedAt: updatedAt,
                    fingerprint: record.fingerprint))
            }
            if queuedWatchLog { lastWatchLogPush[target.profile] = now }
            // A record the snapshot has but this device no longer holds is a delete. Skipped when the scope could not be
            // read in full, so a damaged local file can never delete data on the server.
            if local.complete {
                for (key, old) in snapshot where local.records[key] == nil && RecordKey.inScope(key, target) {
                    guard let parts = RecordKey.parse(key) else { continue }
                    let updatedAt = max(now, old.updatedAt + 1)
                    pending.append(Pending(
                        key: key,
                        change: changeObject(profile: parts.profile, kind: parts.kind, key: parts.key,
                                             updatedAt: updatedAt, data: nil),
                        updatedAt: updatedAt,
                        fingerprint: nil))
                }
            }
            if target.kind == .progress { clearProgressFlags(target.profile) }
        }

        var sent = 0
        var refused: String?
        var start = 0
        while start < pending.count {
            let end = min(start + SyncRules.pushBatch, pending.count)
            let chunk = Array(pending[start..<end])
            start = end
            lastPushAt = Date().unixMs
            let result = try await client.push(bearer: bearer, changes: chunk.map { $0.change })
            for (index, item) in chunk.enumerated() where result.accepted.contains(index) {
                sent += 1
                if let fingerprint = item.fingerprint {
                    snapshot[item.key] = SyncedRecord(fingerprint: fingerprint, updatedAt: item.updatedAt)
                } else {
                    snapshot.removeValue(forKey: item.key)
                }
            }
            if let reason = result.rejectedReasons.first { refused = reason }
            store.writeSnapshot(snapshot)
        }
        return PushOutcome(sent: sent, refused: refused)
    }

    private func changeObject(profile: String, kind: SyncKind, key: String, updatedAt: Double, data: [String: Any]?) -> [String: Any] {
        var change: [String: Any] = [
            "profileId": profile,
            "kind": kind.rawValue,
            "key": key,
            "updatedAt": Int64(updatedAt),
        ]
        if let data {
            change["data"] = data
        } else {
            change["deleted"] = true
        }
        return change
    }

    /// The time a local change is pushed with: the record's own time when that is newer than the server's, otherwise one past
    /// what the server holds, so a change that does not move the record's time still wins.
    private func stamp(_ intrinsic: Double?, old: SyncedRecord?, now: Double) -> Double {
        let base = max(min(intrinsic ?? now, now), 1)
        guard let old, base <= old.updatedAt else { return base }
        return max(now, old.updatedAt + 1)
    }

    /// A progress record goes out when it is forced (a pause, a close), or when it is due and its position moved. A full
    /// sync (`allProgress`) sends every one that differs from the account: the forced and due marks live in memory only and
    /// are cleared before the request is made, so a push that failed or never ran (the app was suspended, a restart) is
    /// picked up here.
    private func progressMayPush(_ record: LocalRecord, old: SyncedRecord?, now: Double, allProgress: Bool) -> Bool {
        let token = RecordKey.token(record.profile, record.key)
        if allProgress || forced.contains(token) {
            lastProgressPush[token] = now
            return true
        }
        guard due.contains(token) else { return false }
        let moved = old.map { movedEnough(record.body, oldFingerprint: $0.fingerprint) } ?? true
        guard moved else { return false }
        lastProgressPush[token] = now
        return true
    }

    private func movedEnough(_ body: [String: Any], oldFingerprint: String) -> Bool {
        guard let newPosition = (body["position"] as? NSNumber)?.doubleValue,
              let data = oldFingerprint.data(using: .utf8),
              let old = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oldPosition = (old["position"] as? NSNumber)?.doubleValue else { return true }
        return abs(newPosition - oldPosition) > SyncRules.progressMovedSeconds
    }

    private func clearProgressFlags(_ profile: String) {
        let prefix = profile + RecordKey.sep
        forced = forced.filter { !$0.hasPrefix(prefix) }
        due = due.filter { !$0.hasPrefix(prefix) }
    }

    // MARK: Pull

    /// Pages through the account's changes from the cursor, applies them, and moves the cursor only after the last page.
    private func pullAll(bearer: String) async throws -> Bool {
        var changed = false
        var cursor = store.lastServerTs <= 0 ? 0 : max(0, store.lastServerTs - SyncRules.pullOverlapMs)
        var pages = 0
        var more = true
        while more {
            pages += 1
            if pages > SyncRules.maxPages { throw CloudError.badResponse }
            let page = try await client.pull(bearer: bearer, since: cursor)
            if applyPage(page.changes) { changed = true }
            more = page.more
            if more {
                cursor = page.serverTs
            } else {
                store.lastServerTs = page.serverTs
            }
        }
        return changed
    }

    /// Applies one page. Profiles first, then settings, then history, library, progress and the watch log, so a title
    /// exists before its progress. Settings are applied only while this device syncs them.
    private func applyPage(_ changes: [RemoteChange]) -> Bool {
        guard !changes.isEmpty else { return false }
        var changed = false
        let profileChanges = changes.filter { $0.kind == .profile }
        if !profileChanges.isEmpty, applyProfiles(profileChanges) { changed = true }

        let settingChanges = changes.filter { $0.kind == .settings }
        if !settingChanges.isEmpty, syncSettingsOn, applySettings(settingChanges) { changed = true }

        let groups = Dictionary(grouping: changes.filter { $0.kind != .profile && $0.kind != .settings }) {
            SyncScope(profile: $0.profileID, kind: $0.kind)
        }
        for kind in [SyncKind.history, .library, .progress, .watchlog] {
            for (target, list) in groups where target.kind == kind {
                let did: Bool
                switch kind {
                case .history: did = applyHistory(target.profile, list)
                case .library: did = applyLibrary(target.profile, list)
                case .watchlog: did = applyWatchLog(target.profile, list)
                case .progress: did = applyProgress(target.profile, list)
                case .profile, .settings: did = false
                }
                if did { changed = true }
            }
        }
        return changed
    }

    private func applyProfiles(_ changes: [RemoteChange]) -> Bool {
        let stored = LocalStore.profiles()
        guard stored.complete else { return false }
        let fromNothing = replacing && UserDefaults.standard.data(forKey: ProfileKeys.list) == nil
        var list = fromNothing ? [] : stored.list
        let pending: Set<String> = replacing ? [] : pendingKeys(SyncScope(profile: "", kind: .profile))
        var snapshot = store.readSnapshot()
        var changed = false

        for change in changes {
            let key = RecordKey.make(change.profileID, .profile, change.key)
            if pending.contains(key) { continue }
            guard !change.deleted, let data = change.data else {
                // The last profile on the device is never deleted.
                if list.count > 1, list.contains(where: { $0.id == change.key }) {
                    list.removeAll { $0.id == change.key }
                    for base in ProfileKeys.scopedBases {
                        UserDefaults.standard.removeObject(forKey: ProfileKeys.scoped(base, change.key))
                    }
                    snapshot = snapshot.filter { !$0.key.hasPrefix(change.key + RecordKey.sep) }
                    changed = true
                }
                continue
            }
            guard let remote = SyncJSON.decode(Profile.self, data), remote.id == change.key else { continue }
            if Merge.upsertProfile(&list, remote) {
                snapshot[key] = SyncedRecord(fingerprint: Fingerprint.json(SyncJSON.object(remote)), updatedAt: change.updatedAt)
                changed = true
            }
        }
        guard changed else { return false }
        LocalStore.write(ProfileKeys.list, list)
        store.writeSnapshot(snapshot)
        return true
    }

    private func applyHistory(_ profile: String, _ changes: [RemoteChange]) -> Bool {
        let stored = LocalStore.history(profile)
        guard stored.complete else { return false }
        let pending = pendingKeys(SyncScope(profile: profile, kind: .history))
        var snapshot = store.readSnapshot()
        var lists = HistoryLists(live: stored.live, archive: stored.archive)
        var changed = false

        for change in changes {
            let key = RecordKey.make(profile, .history, change.key)
            if pending.contains(key) { continue }
            guard !change.deleted, let data = change.data else {
                lists.remove(change.key)
                snapshot.removeValue(forKey: key)
                changed = true
                continue
            }
            guard let remote = SyncJSON.decode(WatchHistory.Entry.self, data), remote.id == change.key else { continue }
            lists.upsert(remote)
            snapshot[key] = SyncedRecord(fingerprint: Fingerprint.history(SyncJSON.object(remote)), updatedAt: change.updatedAt)
            changed = true
        }
        guard changed else { return false }
        lists.settle()
        LocalStore.writeHistory(profile, lists)
        store.writeSnapshot(snapshot)
        return true
    }

    private func applyLibrary(_ profile: String, _ changes: [RemoteChange]) -> Bool {
        if !syncsLibrary(profile) { return false }
        let storeKey = ProfileKeys.scoped("library.local", profile)
        let stored = LocalStore.read(storeKey, LocalLibrary.Entry.self)
        guard stored.complete else { return false }
        var list = stored.items
        let pending = pendingKeys(SyncScope(profile: profile, kind: .library))
        var snapshot = store.readSnapshot()
        var changed = false

        for change in changes {
            let key = RecordKey.make(profile, .library, change.key)
            if pending.contains(key) { continue }
            guard !change.deleted, let data = change.data else {
                list.removeAll { $0.item.id == change.key }
                snapshot.removeValue(forKey: key)
                changed = true
                continue
            }
            guard let remote = SyncJSON.decode(LocalLibrary.Entry.self, data), remote.item.id == change.key else { continue }
            Merge.upsertLibrary(&list, remote)
            snapshot[key] = SyncedRecord(fingerprint: Fingerprint.json(SyncJSON.object(remote)), updatedAt: change.updatedAt)
            changed = true
        }
        guard changed else { return false }
        list.sort { $0.added > $1.added }
        LocalStore.write(storeKey, list)
        store.writeSnapshot(snapshot)
        return true
    }

    private func applyProgress(_ profile: String, _ changes: [RemoteChange]) -> Bool {
        let stored = LocalStore.history(profile)
        guard stored.complete else { return false }
        let pending = pendingKeys(SyncScope(profile: profile, kind: .progress))
        var snapshot = store.readSnapshot()
        var lists = HistoryLists(live: stored.live, archive: stored.archive)
        var changed = false

        for change in changes {
            let key = RecordKey.make(profile, .progress, change.key)
            if pending.contains(key) { continue }
            // A deleted progress record leaves the local position alone: the history delete handles the title.
            guard !change.deleted, let data = change.data else { continue }
            guard let progress = SyncJSON.decode(ProgressData.self, data) else { continue }
            guard lists.applyProgress(change.key, progress, updatedAt: change.updatedAt) else { continue }
            snapshot[key] = SyncedRecord(fingerprint: Fingerprint.json(SyncJSON.object(progress)), updatedAt: change.updatedAt)
            changed = true
        }
        guard changed else { return false }
        lists.settle()
        LocalStore.writeHistory(profile, lists)
        store.writeSnapshot(snapshot)
        return true
    }

    /// Applies pulled settings. Only the shared keys are written, whatever the record says. A key with a local change that
    /// has not gone out yet is left alone: that change is pushed and wins. Returns true when a value changed. The keys
    /// written or removed are announced once, in `settingsApplied`, after the snapshot is saved.
    private func applySettings(_ changes: [RemoteChange]) -> Bool {
        var snapshot = store.readSnapshot()
        var pendingByProfile: [String: Set<String>] = [:]
        var writes: [String: Any] = [:]
        var removed = Set<String>()
        var touched = false

        for change in changes {
            guard let key = SyncedSettings.defaultsKey(profile: change.profileID, key: change.key) else { continue }
            let composite = RecordKey.make(change.profileID, .settings, change.key)
            if pendingByProfile[change.profileID] == nil {
                let fresh: Set<String> = replacing ? [] : pendingKeys(SyncScope(profile: change.profileID, kind: .settings))
                pendingByProfile[change.profileID] = fresh
            }
            if pendingByProfile[change.profileID]?.contains(composite) == true { continue }
            touched = true

            guard let data = change.data, !change.deleted else {
                writes.removeValue(forKey: key)
                if UserDefaults.standard.object(forKey: key) != nil { removed.insert(key) }
                snapshot.removeValue(forKey: composite)
                continue
            }
            guard let value = SyncedSettings.decode(data), let encoded = SyncedSettings.encode(value) else { continue }
            removed.remove(key)
            // A value is written only when it differs. Both sides are compared as their wire form, so a Data or a number reads the same.
            let current = UserDefaults.standard.object(forKey: key).flatMap { SyncedSettings.encode($0) }
            if current.map({ Fingerprint.json($0) }) != Fingerprint.json(encoded) { writes[key] = value }
            snapshot[composite] = SyncedRecord(fingerprint: Fingerprint.json(encoded), updatedAt: change.updatedAt)
        }

        guard touched else { return false }
        for key in removed { UserDefaults.standard.removeObject(forKey: key) }
        for (key, value) in writes { UserDefaults.standard.set(value, forKey: key) }
        store.writeSnapshot(snapshot)
        let keys = removed.union(writes.keys)
        guard !keys.isEmpty else { return false }
        NotificationCenter.default.post(name: Self.settingsApplied, object: nil, userInfo: ["keys": keys])
        return true
    }

    /// Merges pulled watch-log months into this device's log (see LocalStore.mergeWatchLogs). Deletes are ignored, and a
    /// local change that has not gone out is not skipped: the merge keeps both sides, so nothing is lost. The snapshot takes
    /// the server's form of each month, so a month holding more than the server has differs from the snapshot and is pushed back.
    private func applyWatchLog(_ profile: String, _ changes: [RemoteChange]) -> Bool {
        // Seconds not yet on disk go in first, so the merge sees them. Not during a replace: the wipe has just removed the
        // stored log, and a flush would write the old in-memory copy back.
        if !replacing { flushWatchLog() }
        let stored = LocalStore.watchLog(profile)
        guard stored.complete else { return false }
        let local = stored.days
        var snapshot = store.readSnapshot()
        var merged = local
        var applied = false
        for change in changes {
            // A watch log is never removed from the server, so a delete is ignored.
            guard !change.deleted, let data = change.data else { continue }
            guard change.key.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil else { continue }
            let days = (LocalStore.decodeWatchLogMonth(data) ?? [:]).filter { String($0.key.prefix(7)) == change.key }
            guard !days.isEmpty else { continue }
            merged = LocalStore.mergeWatchLogs(merged, days)
            // The snapshot holds what the server holds: this month in its canonical form, not the merged one.
            snapshot[RecordKey.make(profile, .watchlog, change.key)] = SyncedRecord(
                fingerprint: Fingerprint.json(LocalStore.watchLogBody(days)), updatedAt: change.updatedAt)
            applied = true
        }
        guard applied else { return false }
        let changed = merged != local
        if changed, let encoded = try? JSONEncoder().encode(merged) {
            UserDefaults.standard.set(encoded, forKey: ProfileKeys.scoped("watch.log", profile))
        }
        store.writeSnapshot(snapshot)
        // The live log reads the stored one again now, so a later save cannot write the old in-memory copy back over the merge.
        if changed { watchLogStored() }
        return changed
    }

    // MARK: Local data

    /// Whether this profile's library is synced over Pear.pair (see LocalStore.syncsLibrary).
    private func syncsLibrary(_ profile: String) -> Bool {
        LocalStore.syncsLibrary(profile: profile, simklConnected: simklConnected())
    }

    private func localRecords(_ target: SyncScope) -> LocalSet {
        switch target.kind {
        case .profile:
            return LocalStore.profileRecords()
        case .history:
            return LocalStore.historyRecords(target.profile)
        case .progress:
            return LocalStore.progressRecords(target.profile)
        case .library:
            if !syncsLibrary(target.profile) { return LocalSet(records: [:], complete: false) }
            return LocalStore.libraryRecords(target.profile)
        case .settings:
            // Off: this device holds nothing for the account. Incomplete, so no tombstone is sent either.
            guard syncSettingsOn else { return LocalSet(records: [:], complete: false) }
            let snapshot = store.readSnapshot()
            return LocalSet(records: SyncedSettings.localRecords(profile: target.profile,
                                                                 hasSnapshotEntry: { snapshot[$0] != nil }),
                            complete: true)
        case .watchlog:
            return LocalStore.watchLogRecords(target.profile)
        }
    }

    /// Keys whose local record differs from the snapshot, or that the snapshot has and this device no longer holds.
    private func pendingKeys(_ target: SyncScope) -> Set<String> {
        let snapshot = store.readSnapshot()
        let local = localRecords(target)
        var out = Set<String>()
        for (key, record) in local.records where snapshot[key]?.fingerprint != record.fingerprint {
            out.insert(key)
        }
        if local.complete {
            for key in snapshot.keys where RecordKey.inScope(key, target) && local.records[key] == nil {
                out.insert(key)
            }
        }
        return out
    }

    /// Before a replace: this device's synced data goes, and the snapshot with it. The account's data comes in by the pull.
    /// With the settings switch on, the shared settings go too, so the account's settings are the only ones left.
    private func wipeLocalSyncData() {
        var keys: [String] = [ProfileKeys.list]
        let profileIDs = LocalStore.profiles().list.map(\.id)
        for id in profileIDs {
            keys.append(ProfileKeys.scoped("watch.history", id))
            keys.append(ProfileKeys.scoped("watch.archive", id))
            keys.append(ProfileKeys.scoped("library.local", id))
            keys.append(ProfileKeys.scoped("watch.log", id))
        }
        let settingKeys: [String] = syncSettingsOn
            ? SyncedSettings.allDefaultsKeys(profileIDs: profileIDs).filter { UserDefaults.standard.object(forKey: $0) != nil }
            : []
        keys.append(contentsOf: settingKeys)
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        store.writeSnapshot([:])
        // The screens and the add-on list must not keep showing what was just removed.
        if !settingKeys.isEmpty {
            NotificationCenter.default.post(name: Self.settingsApplied, object: nil, userInfo: ["keys": Set(settingKeys)])
        }
        // The live watch log must not keep the removed copy, or the next save would write it back.
        watchLogStored()
    }
}
