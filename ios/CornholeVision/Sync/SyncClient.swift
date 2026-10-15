import Foundation
import UIKit

/// WebSocket link to the Cloudflare Worker (worker/). Optional — the app
/// scores fine with no network. Reconnects with backoff; delivers state on main.
final class SyncClient: NSObject, URLSessionWebSocketDelegate {
    enum Status: Equatable { case off, connecting, connected, disconnected }

    private(set) var status: Status = .off
    var onStatus: ((Status) -> Void)?
    var onState: ((GameState) -> Void)?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var code = ""
    private var role = "scorer"
    private var board = 1
    private var reconnectDelay: TimeInterval = 1
    private var closedByUser = false
    private var pingTimer: Timer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var lastLiveSent = Date.distantPast
    private var pendingLive: LiveState?

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    var isEnabled: Bool { !AppConfig.syncBaseURL.isEmpty }

    func connect(code: String, role: String, board: Int) {
        guard isEnabled else { return }
        self.code = code
        self.role = role
        self.board = board
        closedByUser = false
        open()
    }

    func disconnect() {
        closedByUser = true
        pingTimer?.invalidate()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        set(.off)
    }

    private func open() {
        guard var comps = URLComponents(string: AppConfig.syncBaseURL) else { return }
        comps.scheme = comps.scheme == "http" ? "ws" : "wss"
        comps.path = "/ws/\(code)"
        comps.queryItems = [URLQueryItem(name: "role", value: role), URLQueryItem(name: "board", value: String(board))]
        guard let url = comps.url else { return }
        set(.connecting)
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receive()
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.handleClose()
            case .success(let message):
                if case .string(let text) = message, let data = text.data(using: .utf8),
                   let msg = try? self.decoder.decode(InboundMessage.self, from: data) {
                    if let state = msg.state {
                        DispatchQueue.main.async { self.onState?(state) }
                    }
                }
                self.receive()
            }
        }
    }

    private func handleClose() {
        pingTimer?.invalidate()
        task = nil
        guard !closedByUser else { return }
        set(.disconnected)
        let delay = reconnectDelay
        reconnectDelay = min(15, reconnectDelay * 2)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.closedByUser else { return }
            self.open()
        }
    }

    private func set(_ s: Status) {
        status = s
        DispatchQueue.main.async { self.onStatus?(s) }
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol proto: String?) {
        reconnectDelay = 1
        set(.connected)
        send(OutboundMessage(type: "hello", role: role, board: board, name: UIDevice.current.name))
        DispatchQueue.main.async {
            self.pingTimer?.invalidate()
            self.pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                self?.task?.sendPing { _ in }
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        handleClose()
    }

    // MARK: Sending

    func send(_ message: OutboundMessage) {
        guard let task, status == .connected, let data = try? encoder.encode(message),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    /// Throttled: at most ~6 live updates per second.
    func sendLive(_ live: LiveState) {
        pendingLive = live
        let now = Date()
        if now.timeIntervalSince(lastLiveSent) >= 0.16 {
            lastLiveSent = now
            send(OutboundMessage(type: "live", board: live.board, live: live))
            pendingLive = nil
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) { [weak self] in
                guard let self, let p = self.pendingLive else { return }
                self.lastLiveSent = Date()
                self.send(OutboundMessage(type: "live", board: p.board, live: p))
                self.pendingLive = nil
            }
        }
    }

    func sendSetup(teams: [TeamInfo], target: Int) {
        send(OutboundMessage(type: "setup", teams: teams, target: target))
    }

    func sendRound(_ result: RoundResult) {
        send(OutboundMessage(type: "round", board: result.board, result: result))
    }

    func sendUndo() { send(OutboundMessage(type: "undo")) }
    func sendReset() { send(OutboundMessage(type: "reset")) }
    func sendTeams(_ teams: [TeamInfo]) { send(OutboundMessage(type: "teams", teams: teams)) }
}
