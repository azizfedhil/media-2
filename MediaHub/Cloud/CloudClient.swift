import Foundation

/// A failure from the cloud. `quota` means a free-plan daily cap is used up: stop, keep the data, and retry after 00:00 UTC.
enum CloudError: Error, LocalizedError {
    /// No connection, or the request never got an answer.
    case network
    /// A free-plan daily cap is used up (HTTP 503 with `quota`).
    case quota(String)
    /// The server refused the request: a 4xx answer, or a 5xx other than quota. `code` is its machine code.
    case rejected(status: Int, code: String, message: String)
    /// The answer was not the shape the contract promises.
    case badResponse

    var errorDescription: String? {
        switch self {
        case .network: return "No connection to Pear.pair."
        case .quota(let message): return message
        case .rejected(_, _, let message): return message
        case .badResponse: return "Pear.pair sent an answer the app doesn't understand."
        }
    }
}

/// Plain JSON over HTTPS to the Worker. Requests and answers are JSON objects (cloud/CLOUD_API.md §1). Nothing here logs
/// the request, because a request can carry a device token.
struct CloudClient {
    let base: URL

    /// Sends one request and returns the JSON object it answers with (an empty object when there is no body).
    func send(_ method: String, _ path: String, bearer: String? = nil,
              body: [String: Any]? = nil, query: [URLQueryItem] = []) async throws -> [String: Any] {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw CloudError.badResponse }
        parts.path = path
        parts.queryItems = query.isEmpty ? nil : query
        guard let url = parts.url else { throw CloudError.badResponse }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let answer: (Data, URLResponse)
        do {
            answer = try await URLSession.shared.data(for: request)
        } catch {
            throw CloudError.network
        }
        let (data, response) = answer
        guard let http = response as? HTTPURLResponse else { throw CloudError.badResponse }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if (200..<300).contains(http.statusCode) {
            if let json { return json }
            if data.isEmpty { return [:] }
            throw CloudError.badResponse
        }
        let code = json?["error"] as? String ?? "internal"
        let message = json?["message"] as? String ?? "Pear.pair had a problem."
        if http.statusCode == 503 && code == "quota" { throw CloudError.quota(message) }
        throw CloudError.rejected(status: http.statusCode, code: code, message: message)
    }
}

/// Typed reads of a JSON answer. A missing or wrong-typed field is a bad answer, not a crash.
extension Dictionary where Key == String, Value == Any {
    func string(_ name: String) throws -> String {
        guard let value = self[name] as? String else { throw CloudError.badResponse }
        return value
    }

    func double(_ name: String) throws -> Double {
        guard let value = (self[name] as? NSNumber)?.doubleValue else { throw CloudError.badResponse }
        return value
    }

    func array(_ name: String) throws -> [Any] {
        guard let value = self[name] as? [Any] else { throw CloudError.badResponse }
        return value
    }
}
