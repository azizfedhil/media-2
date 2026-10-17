import Foundation
import Observation

/// The Pear.pair account on this device, and what the server last agreed with.
///
/// The device token lives in the Keychain. The cursor, the last sync time and the snapshot are not secrets, but none of this
/// is in a settings backup: SettingsBackup exports only the keys it lists, and the Keychain fallback keys are not among them.
/// Observable, so a view that reads `PairSync.isSignedIn` updates when the device signs in or out.
@MainActor @Observable
final class PairStore {
    private enum Key {
        static let account = "pear.pair.account"
        static let device = "pear.pair.device"
        static let bearer = "pear.pair.bearer"
        static let cursor = "pear.pair.cursor"
        static let lastSync = "pear.pair.lastSync"
    }

    /// Nil when this device is not signed in.
    private(set) var credentials: PairCredentials?
    @ObservationIgnored private var snapshotCache: [String: SyncedRecord]?

    init() {
        if let account = Keychain.get(Key.account), let device = Keychain.get(Key.device), let bearer = Keychain.get(Key.bearer) {
            credentials = PairCredentials(accountID: account, deviceID: device, bearer: bearer)
        }
    }

    var isSignedIn: Bool { credentials != nil }

    func save(_ value: PairCredentials) {
        Keychain.set(value.accountID, Key.account)
        Keychain.set(value.deviceID, Key.device)
        Keychain.set(value.bearer, Key.bearer)
        credentials = value
    }

    /// Forgets the account on this device: the credentials, the cursor and the snapshot. The local data stays.
    func forget() {
        Keychain.remove(Key.account)
        Keychain.remove(Key.device)
        Keychain.remove(Key.bearer)
        UserDefaults.standard.removeObject(forKey: Key.cursor)
        UserDefaults.standard.removeObject(forKey: Key.lastSync)
        credentials = nil
        writeSnapshot([:])
    }

    /// The server's serverTs of the last complete pull, in Unix ms. Zero means never pulled.
    var lastServerTs: Double {
        get { UserDefaults.standard.double(forKey: Key.cursor) }
        set { UserDefaults.standard.set(newValue, forKey: Key.cursor) }
    }

    var lastSyncAt: Date? {
        get { UserDefaults.standard.object(forKey: Key.lastSync) as? Date }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: Key.lastSync)
            } else {
                UserDefaults.standard.removeObject(forKey: Key.lastSync)
            }
        }
    }

    /// What the server last agreed with, by record key. Kept in a file: it can be large.
    func readSnapshot() -> [String: SyncedRecord] {
        if let snapshotCache { return snapshotCache }
        let loaded = (try? Data(contentsOf: snapshotURL))
            .flatMap { try? JSONDecoder().decode([String: SyncedRecord].self, from: $0) } ?? [:]
        snapshotCache = loaded
        return loaded
    }

    func writeSnapshot(_ value: [String: SyncedRecord]) {
        snapshotCache = value
        if value.isEmpty {
            try? FileManager.default.removeItem(at: snapshotURL)
            return
        }
        try? FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: snapshotURL, options: .atomic)
        }
    }

    private var snapshotURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return folder.appendingPathComponent("pear-pair-snapshot.json")
    }
}
