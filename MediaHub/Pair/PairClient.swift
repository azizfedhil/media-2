import Foundation

/// The Pear.pair routes (cloud/CLOUD_API.md §2), one function per route. Each answer is read into plain values.
struct PairClient {
    let cloud: CloudClient

    init(base: URL = CloudConfig.pairBaseURL) {
        cloud = CloudClient(base: base)
    }

    /// Makes an account and signs this device in. The recovery key comes back once, and must be kept.
    func createAccount(deviceName: String, platform: String) async throws -> (credentials: PairCredentials, recoveryKey: String) {
        let answer = try await cloud.send("POST", "/v1/pair/accounts", body: ["deviceName": deviceName, "platform": platform])
        let credentials = try readCredentials(answer)
        let recoveryKey = try answer.string("recoveryKey")
        return (credentials, recoveryKey)
    }

    /// Joins an account with a pair code from a device that is already signed in.
    func redeem(code: String, deviceName: String, platform: String) async throws -> PairCredentials {
        let answer = try await cloud.send("POST", "/v1/pair/redeem",
                                          body: ["code": code, "deviceName": deviceName, "platform": platform])
        return try readCredentials(answer)
    }

    /// Joins an account with its ID and recovery key.
    func recover(accountID: String, recoveryKey: String, deviceName: String, platform: String) async throws -> PairCredentials {
        let answer = try await cloud.send("POST", "/v1/pair/recover",
                                          body: ["accountId": accountID, "recoveryKey": recoveryKey,
                                                 "deviceName": deviceName, "platform": platform])
        let deviceID = try answer.string("deviceId")
        let bearer = try answer.string("deviceToken")
        return PairCredentials(accountID: accountID, deviceID: deviceID, bearer: bearer)
    }

    /// A pair code for another device to join with. Valid for five minutes, and once.
    func makeCode(bearer: String) async throws -> (code: String, expiresAt: Double) {
        let answer = try await cloud.send("POST", "/v1/pair/codes", bearer: bearer)
        let code = try answer.string("code")
        let expiresAt = try answer.double("expiresAt")
        return (code, expiresAt)
    }

    func devices(bearer: String) async throws -> [PairDevice] {
        let answer = try await cloud.send("GET", "/v1/pair/devices", bearer: bearer)
        var out: [PairDevice] = []
        for item in try answer.array("devices") {
            guard let d = item as? [String: Any],
                  let id = d["id"] as? String,
                  let name = d["name"] as? String else { continue }
            out.append(PairDevice(
                id: id,
                name: name,
                platform: d["platform"] as? String ?? "",
                createdAt: (d["createdAt"] as? NSNumber)?.doubleValue ?? 0,
                lastSeenAt: (d["lastSeenAt"] as? NSNumber)?.doubleValue ?? 0,
                current: d["current"] as? Bool ?? false
            ))
        }
        return out
    }

    func revokeDevice(bearer: String, id: String) async throws {
        _ = try await cloud.send("DELETE", "/v1/pair/devices/\(id)", bearer: bearer)
    }

    func deleteAccount(bearer: String) async throws {
        _ = try await cloud.send("DELETE", "/v1/pair/account", bearer: bearer)
    }

    /// Pushes changes (at most 200). Returns which were taken and why the others were not.
    func push(bearer: String, changes: [[String: Any]]) async throws -> PushResult {
        let answer = try await cloud.send("POST", "/v1/pair/sync", bearer: bearer, body: ["changes": changes])
        let acceptedRaw = answer["accepted"] as? [Any] ?? []
        let accepted = Set(acceptedRaw.compactMap { ($0 as? NSNumber)?.intValue })
        let rejectedRaw = answer["rejected"] as? [[String: Any]] ?? []
        let reasons = rejectedRaw.compactMap { $0["reason"] as? String }
        let serverTs = try answer.double("serverTs")
        return PushResult(accepted: accepted, rejectedReasons: reasons, serverTs: serverTs)
    }

    /// One page of the account's changes after `since` (Unix ms), oldest first.
    func pull(bearer: String, since: Double) async throws -> PullPage {
        let answer = try await cloud.send("GET", "/v1/pair/sync", bearer: bearer, query: [
            URLQueryItem(name: "since", value: String(Int64(since))),
            URLQueryItem(name: "limit", value: String(SyncRules.pullLimit)),
        ])
        var changes: [RemoteChange] = []
        for item in try answer.array("changes") {
            guard let c = item as? [String: Any],
                  let profileID = c["profileId"] as? String,
                  let kindName = c["kind"] as? String,
                  let kind = SyncKind(rawValue: kindName),
                  let key = c["key"] as? String,
                  let updatedAt = (c["updatedAt"] as? NSNumber)?.doubleValue,
                  let serverTs = (c["serverTs"] as? NSNumber)?.doubleValue else { continue }
            changes.append(RemoteChange(
                serverTs: serverTs,
                profileID: profileID,
                kind: kind,
                key: key,
                updatedAt: updatedAt,
                deleted: c["deleted"] as? Bool ?? false,
                data: c["data"] as? [String: Any]
            ))
        }
        let serverTs = try answer.double("serverTs")
        let more = answer["more"] as? Bool ?? false
        return PullPage(changes: changes, serverTs: serverTs, more: more)
    }

    private func readCredentials(_ answer: [String: Any]) throws -> PairCredentials {
        let accountID = try answer.string("accountId")
        let deviceID = try answer.string("deviceId")
        let bearer = try answer.string("deviceToken")
        return PairCredentials(accountID: accountID, deviceID: deviceID, bearer: bearer)
    }
}
