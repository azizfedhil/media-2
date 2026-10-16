import Foundation

// Batch S2, watch party logic. Not compiled: the owner's CI builds it.

enum PartySocketError: Error {
    case notOpen
}

/// One WebSocket to a room. Incoming messages arrive as decoded `PartyServerMessage`s. A close says what HTTP status the
/// handshake had (nil once the socket was open), so the session can tell a full room or a quota from a dropped network.
final class PartySocket {
    enum Event: Sendable {
        case message(PartyServerMessage)
        case closed(httpStatus: Int?)
    }

    private var task: URLSessionWebSocketTask?

    /// Opens the socket and returns its events. Send `hello` before anything else.
    func open(_ url: URL) -> AsyncStream<Event> {
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        return AsyncStream<Event> { continuation in
            let reader = Task {
                while !Task.isCancelled {
                    do {
                        let message = try await task.receive()
                        let data: Data
                        switch message {
                        case .string(let text): data = Data(text.utf8)
                        case .data(let raw): data = raw
                        @unknown default: continue
                        }
                        if let decoded = PartyMessageDecoder.decode(data) {
                            continuation.yield(.message(decoded))
                        }
                    } catch {
                        let status = (task.response as? HTTPURLResponse)?.statusCode
                        continuation.yield(.closed(httpStatus: status))
                        continuation.finish()
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                reader.cancel()
                task.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    func send(_ data: Data) async throws {
        guard let task else { throw PartySocketError.notOpen }
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }
}
