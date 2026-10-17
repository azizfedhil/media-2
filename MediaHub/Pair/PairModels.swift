import Foundation

/// The kinds of synced record (cloud/CLOUD_API.md §2.2). The raw value is the wire name.
enum SyncKind: String, Sendable {
    case profile, history, library, progress, settings, watchlog
}

/// Limits and cadences. The same numbers as SyncRules in Kotlin (cloud/CLOUD_API.md §4 and the follow-up file).
enum SyncRules {
    static let pushBatch = 200
    static let pullLimit = 500
    static let pullOverlapMs: Double = 5_000
    static let debounceSeconds: Double = 5
    static let minPushGapSeconds: Double = 15
    static let pullEverySeconds: Double = 600
    static let progressEveryMs: Double = 60_000
    static let progressMovedSeconds: Double = 15
    static let retryMinSeconds: Double = 30
    static let retryMaxSeconds: Double = 600
    static let historyLiveCap = 30
    static let maxPages = 1_000
    /// The profile id of the account-wide settings records (ACCOUNT_SCOPE in Kotlin).
    static let accountScope = "_account"
    /// A profile's watch log goes out at most this often.
    static let watchLogEveryMs: Double = 5 * 60_000
    /// A watch-log hour above this is invalid: two hours plus one tick's overshoot (MAX_HOUR_SECONDS in Kotlin).
    static let maxHourSeconds = 2 * 3_600 + 120
    /// Fields of a history entry that move with playback. They travel as `progress`, so they are left out of the change check.
    static let playbackFields: Set<String> = ["position", "duration", "updated"]
}

/// Playback progress as a `progress` record carries it (cloud/CLOUD_API.md §2.2).
struct ProgressData: Codable, Equatable {
    var position: Double
    var duration: Double
    var season: Int?
    var episode: Int?
}

/// What the Pear.pair screen shows. Never a token and never a URL.
struct PairSyncState: Equatable {
    var syncing = false
    var lastSyncAt: Date?
    /// Set while the free-plan quota is used up. Sync resumes at this time (00:00 UTC).
    var pausedUntil: Date?
    var error: String?
    /// The server refused this device's token: it was revoked elsewhere. Pair the device again to sync.
    var needsSignIn = false
}

/// This device's place in an account. The bearer is `<deviceId>.<secret>`. It is kept in the Keychain only.
struct PairCredentials: Equatable {
    let accountID: String
    let deviceID: String
    let bearer: String
}

/// A device on the account, as the device list shows it.
struct PairDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let platform: String
    let createdAt: Double
    let lastSeenAt: Double
    let current: Bool
}

/// One record as the server sends it in a pull.
struct RemoteChange {
    let serverTs: Double
    let profileID: String
    let kind: SyncKind
    let key: String
    /// Unix ms: the time the record was last changed.
    let updatedAt: Double
    let deleted: Bool
    let data: [String: Any]?
}

struct PullPage {
    let changes: [RemoteChange]
    let serverTs: Double
    let more: Bool
}

struct PushResult {
    /// Indexes of the changes the server took.
    let accepted: Set<Int>
    let rejectedReasons: [String]
    let serverTs: Double
}

/// One scope: a kind of record for one profile. `profile` is "" for the profile list, which is global.
struct SyncScope: Hashable {
    let profile: String
    let kind: SyncKind
}

/// A record as this device holds it now.
struct LocalRecord {
    let profile: String
    let kind: SyncKind
    let key: String
    /// The record's own time in Unix ms, when it has one.
    let intrinsicAt: Double?
    let body: [String: Any]
    /// What counts as a change for this kind. Only compared on this device.
    let fingerprint: String
}

struct LocalSet {
    let records: [String: LocalRecord]
    /// False when a stored value could not be read. Deletes are then not worked out, so no data is deleted on the server.
    let complete: Bool
}

/// What the snapshot keeps for a record the server holds: the fingerprint it was agreed with, and the time it was pushed with.
struct SyncedRecord: Codable, Equatable {
    let fingerprint: String
    let updatedAt: Double
}

/// A pair code as the settings screen shows it.
struct PairCodeInfo: Equatable {
    let code: String
    let expires: Date
}
