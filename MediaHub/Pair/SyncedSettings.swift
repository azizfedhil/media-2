import Foundation

// The settings Pear.pair shares when the person turns on "Sync settings" on a device. Port of Kotlin SyncedSettings.kt.
// The list is explicit on purpose: nothing outside it leaves the device, and a pulled record can write nothing outside it.
// Keychain secrets (the Simkl and Pear.pair tokens), the P2P switch and the pair.* keys are never listed here.

/// What a settings record holds for one key, and which keys are shared.
///
/// A record's `data` is `{"t": <type>, "v": <value>}`. The type codes: `s` text, `b` flag, `i` whole number, `d` number,
/// `l` list of text, `j` JSON text (a `Data` value in UserDefaults). A value of another kind is not synced.
@MainActor
enum SyncedSettings {
    /// Account-wide keys. Their records use the profile id `SyncRules.accountScope`.
    static let accountKeys: Set<String> = [
        // Add-ons
        "addon.manifestURLs", "addon.disabled", "addon.catalogPicker",
        // API keys
        "tmdb.key", "tvdb.key", "tvdb.pin", "mdblist.key", "mdblist.lists",
        // Subtitles and audio. audio.lang has no control on iOS, but a value from another device is kept, never deleted.
        "subs.baseURL", "subs.online", "sub.lang", "sub.style", "audio.lang",
        // Look and layout. ui.landscapeLayout and player.glass are not shared, as in Kotlin.
        "ui.accent", "ui.networkBadges", "ui.titleLogos", "library.collapsed",
        // Playback
        "player.autoplayNext", "player.pip", "player.pillPinned", "player.pillOrder", "skip.enabled", "skip.fallbackSeconds",
    ]

    /// Per-profile keys. Their records use the profile's own id, and their local key is scoped to that profile.
    static let profileKeys: Set<String> = ["content.prefs"]

    /// The add-on list a fresh install starts with (the default in AddonStore).
    private static let defaultAddonList = ["https://v3-cinemeta.strem.io/manifest.json"]

    /// The local key for `key` in the scope of `profile`, or nil when `key` is not shared in that scope.
    static func defaultsKey(profile: String, key: String) -> String? {
        if profile == SyncRules.accountScope { return accountKeys.contains(key) ? key : nil }
        if profileKeys.contains(key) { return ProfileKeys.scoped(key, profile) }
        return nil
    }

    /// Every local key the settings sync can touch, for the given profile ids.
    static func allDefaultsKeys(profileIDs: [String]) -> [String] {
        var keys = accountKeys.sorted()
        for id in profileIDs {
            for key in profileKeys.sorted() {
                keys.append(ProfileKeys.scoped(key, id))
            }
        }
        return keys
    }

    /// The records this device holds for one scope: each shared key that has a value, keyed by its composite key.
    /// A key set only to the default add-on list is left out while the snapshot has no record for it, so a fresh device
    /// cannot overwrite the account's add-on list with the default. `hasSnapshotEntry` takes a composite key.
    static func localRecords(profile: String, hasSnapshotEntry: (String) -> Bool) -> [String: LocalRecord] {
        var out: [String: LocalRecord] = [:]
        let keys = profile == SyncRules.accountScope ? accountKeys : profileKeys
        for key in keys {
            guard let local = defaultsKey(profile: profile, key: key),
                  let value = UserDefaults.standard.object(forKey: local) else { continue }
            let composite = RecordKey.make(profile, .settings, key)
            if key == "addon.manifestURLs", (value as? [String]) == defaultAddonList, !hasSnapshotEntry(composite) {
                continue
            }
            guard let data = encode(value) else { continue }
            out[composite] = LocalRecord(profile: profile, kind: .settings, key: key, intrinsicAt: nil,
                                         body: data, fingerprint: Fingerprint.json(data))
        }
        return out
    }

    /// The wire form of one stored value, or nil for a kind that is not synced (a dictionary, a date, a non-finite number).
    static func encode(_ value: Any) -> [String: Any]? {
        if let text = value as? String { return tagged("s", text) }
        if let data = value as? Data {
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return tagged("j", text)
        }
        if let list = value as? [String] { return tagged("l", list) }
        guard let number = (value as AnyObject) as? NSNumber else { return nil }
        // A flag is an NSNumber too, so it is told apart by its CoreFoundation type, not by its value.
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return tagged("b", number.boolValue) }
        let objCType = String(cString: number.objCType)
        if objCType == "d" || objCType == "f" {
            let real = number.doubleValue
            return real.isFinite ? tagged("d", real) : nil
        }
        return tagged("i", number.int64Value)
    }

    /// The value a pulled record holds, or nil when the record is not one this device can read.
    static func decode(_ data: [String: Any]) -> Any? {
        let value = data["v"]
        switch (data["t"] as? String) ?? "" {
        case "s":
            return value as? String
        case "b":
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        case "i":
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return Int(exactly: number.doubleValue)
        case "d":
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let real = number.doubleValue
            return real.isFinite ? real : nil
        case "l":
            return value as? [String]
        case "j":
            return (value as? String).map { Data($0.utf8) }
        default:
            return nil
        }
    }

    private static func tagged(_ type: String, _ value: Any) -> [String: Any] {
        ["t": type, "v": value]
    }
}
