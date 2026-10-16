import Foundation

// Batch S2, watch party logic. Not compiled: the owner's CI builds it.
// The wire format from the plan (section 5) and cloud/CLOUD_API.md §3. Kotlin reads and writes the same JSON.
// Reads ignore fields they do not know, so the server can add fields without breaking an older app.

/// What a room plays: a description of a title, never a stream URL. Each guest resolves it through their own add-ons,
/// because debrid links belong to one account.
struct PartySource: Codable, Equatable, Sendable {
    /// "movie" or "series".
    let type: String
    let imdb: String
    let title: String
    var year: Int? = nil
    var season: Int? = nil
    var episode: Int? = nil
    var episodeTitle: String? = nil
    var addonId: String? = nil
    var signature: String? = nil
    var p2pHash: String? = nil
    var fileIdx: Int? = nil
    /// Read when the server sends one. This app never sends one: no URLs over the party channel (K6).
    var poster: String? = nil
}

/// The room's playback as the server keeps it. While playing, the position now is
/// `pos + (serverNow - at) / 1000 * rate` seconds. `rev` rises with every change.
struct PartyState: Decodable, Equatable, Sendable {
    let rev: Int
    let source: PartySource?
    let playing: Bool
    let pos: Double
    /// Server time in Unix ms when `pos` was stamped.
    let at: Double
    let rate: Double
}

struct PartyMember: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    /// "host" or "guest".
    let role: String
    let ready: Bool
    let connected: Bool
}

struct PartySuggestion: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    /// The member id of whoever suggested it.
    let from: String
    let source: PartySource
    let note: String?
}

struct PartyRequest: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    /// The member id of the guest who asked.
    let from: String
    /// "play" or "pause".
    let action: String
}

/// Everything a welcome carries about the room as it is now.
struct PartySnapshot: Decodable, Sendable {
    let members: [PartyMember]
    let state: PartyState?
    let suggestions: [PartySuggestion]
    let autoApprove: Bool
    let locked: Bool

    private enum Keys: String, CodingKey {
        case members, state, suggestions, autoApprove, locked
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        // The members here are a plain list; also accept the {list: [...]} shape of the members message.
        if let list = try? c.decode([PartyMember].self, forKey: .members) {
            members = list
        } else {
            members = (try? c.decode(PartyMemberList.self, forKey: .members))?.list ?? []
        }
        state = try? c.decodeIfPresent(PartyState.self, forKey: .state)
        suggestions = (try? c.decode([PartySuggestion].self, forKey: .suggestions)) ?? []
        autoApprove = (try? c.decodeIfPresent(Bool.self, forKey: .autoApprove)) ?? false
        locked = (try? c.decodeIfPresent(Bool.self, forKey: .locked)) ?? false
    }
}

/// A message from the server, decoded. `.other` is a type this build does not know yet: ignore it.
enum PartyServerMessage: Sendable {
    case welcome(memberId: String, token: String?, role: String, snapshot: PartySnapshot)
    case state(PartyState)
    case members([PartyMember])
    case suggestion(PartySuggestion)
    case request(PartyRequest)
    case resolved(id: String, ok: Bool)
    case error(code: String, message: String)
    case closed(reason: String)
    case pong(clientMs: Double, serverMs: Double)
    case other(type: String)
}

fileprivate struct PartyMemberList: Decodable {
    let list: [PartyMember]
}

enum PartyMessageDecoder {
    private struct Envelope: Decodable { let t: String }
    private struct WelcomeWire: Decodable {
        let memberId: String
        let token: String?
        let role: String
        let snapshot: PartySnapshot
    }
    private struct ResolvedWire: Decodable { let id: String; let ok: Bool }
    private struct ErrorWire: Decodable { let code: String; let message: String? }
    private struct ClosedWire: Decodable { let reason: String }
    private struct PongWire: Decodable { let c: Double; let s: Double }

    /// Nil when the bytes are not a message at all.
    static func decode(_ data: Data) -> PartyServerMessage? {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else { return nil }
        switch envelope.t {
        case "welcome":
            guard let w = try? decoder.decode(WelcomeWire.self, from: data) else { return nil }
            return .welcome(memberId: w.memberId, token: w.token, role: w.role, snapshot: w.snapshot)
        case "state":
            guard let s = try? decoder.decode(PartyState.self, from: data) else { return nil }
            return .state(s)
        case "members":
            guard let m = try? decoder.decode(PartyMemberList.self, from: data) else { return nil }
            return .members(m.list)
        case "suggestion":
            guard let s = try? decoder.decode(PartySuggestion.self, from: data) else { return nil }
            return .suggestion(s)
        case "request":
            guard let r = try? decoder.decode(PartyRequest.self, from: data) else { return nil }
            return .request(r)
        case "resolved":
            guard let r = try? decoder.decode(ResolvedWire.self, from: data) else { return nil }
            return .resolved(id: r.id, ok: r.ok)
        case "error":
            guard let e = try? decoder.decode(ErrorWire.self, from: data) else { return nil }
            return .error(code: e.code, message: e.message ?? "")
        case "closed":
            guard let c = try? decoder.decode(ClosedWire.self, from: data) else { return nil }
            return .closed(reason: c.reason)
        case "pong":
            guard let p = try? decoder.decode(PongWire.self, from: data) else { return nil }
            return .pong(clientMs: p.c, serverMs: p.s)
        default:
            return .other(type: envelope.t)
        }
    }
}

/// Builds the JSON the client sends. Every message has a "t" (its type).
enum PartyOutgoing {
    static func make(_ type: String, _ fields: [String: Any] = [:]) -> Data {
        var object = fields
        object["t"] = type
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}

/// Room codes: 6 characters from the same unambiguous alphabet as pair codes.
enum PartyCode {
    static let alphabet = Set("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    /// Upper-cases the input and keeps only alphabet characters. Nil unless six are left.
    static func clean(_ raw: String) -> String? {
        let code = String(raw.uppercased().filter { alphabet.contains($0) })
        return code.count == 6 ? code : nil
    }
}

/// Display names: no control characters, trimmed, 1 to 24 characters.
enum PartyName {
    static func clean(_ raw: String) -> String? {
        var visible = String.UnicodeScalarView()
        visible.append(contentsOf: raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        let trimmed = String(visible).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(24))
    }
}
