import Foundation
import Network

/// One Chrome tab reporting its media state through the companion extension.
struct ExtensionTab {
    let tabId: String
    let title: String
    let artist: String
    let host: String
    let playbackState: String // "playing", "paused", "none"
    let position: Double
    let duration: Double
}

/// Tiny localhost HTTP server the Chrome extension talks to.
/// Endpoints:
/// - POST /tab      {tabId,title,artist,host,playbackState,position,duration}
/// - POST /tab-gone {tabId}
/// - GET  /commands?tabId=... -> {"command":"playpause"} (cleared on read)
/// - OPTIONS *      CORS preflight (extensions POST JSON cross-origin).
final class ExtensionBridge {
    static weak var shared: ExtensionBridge?

    private var listener: NWListener?
    private(set) var tabs: [String: ExtensionTab] = [:]
    private var pendingCommands: [String: String] = [:]
    var onTabsChanged: (() -> Void)?

    init() {
        ExtensionBridge.shared = self
    }

    func start(port: UInt16 = 48123) {
        let params = NWParameters.tcp
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        do {
            listener = try NWListener(using: params, on: endpointPort)
        } catch {
            return
        }
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener?.start(queue: .main)
    }

    func queueCommand(tabId: String, command: String) {
        pendingCommands[tabId] = command
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            defer { connection.cancel() }
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { return }
            let parts = request.components(separatedBy: "\r\n\r\n")
            let head = parts.first ?? ""
            let body = parts.dropFirst().joined(separator: "\r\n\r\n")
            let requestLine = head.components(separatedBy: "\r\n").first ?? ""
            var responseBody = "{}"
            if requestLine.hasPrefix("OPTIONS") {
                // CORS preflight: no body needed.
            } else if requestLine.hasPrefix("POST /tab-gone") {
                if let json = self.json(body), let id = json["tabId"] as? String {
                    self.tabs.removeValue(forKey: id)
                    self.onTabsChanged?()
                }
            } else if requestLine.hasPrefix("POST /tab ") {
                if let json = self.json(body),
                   let id = json["tabId"] as? String {
                    let tab = ExtensionTab(
                        tabId: id,
                        title: (json["title"] as? String) ?? "",
                        artist: (json["artist"] as? String) ?? "",
                        host: (json["host"] as? String) ?? "",
                        playbackState: (json["playbackState"] as? String) ?? "none",
                        position: (json["position"] as? NSNumber)?.doubleValue ?? 0,
                        duration: (json["duration"] as? NSNumber)?.doubleValue ?? 0
                    )
                    if !tab.title.isEmpty {
                        self.tabs[id] = tab
                        self.onTabsChanged?()
                    }
                }
            } else if requestLine.hasPrefix("GET /commands") {
                let tabId = self.queryValue(requestLine, key: "tabId") ?? ""
                if let command = self.pendingCommands.removeValue(forKey: tabId) {
                    responseBody = "{\"command\":\"\(command)\"}"
                } else {
                    responseBody = "{}"
                }
            }
            let http = "HTTP/1.1 200 OK\r\n" +
                "Content-Type: application/json\r\n" +
                "Access-Control-Allow-Origin: *\r\n" +
                "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" +
                "Access-Control-Allow-Headers: Content-Type\r\n" +
                "Content-Length: \(responseBody.utf8.count)\r\n" +
                "Connection: close\r\n\r\n\(responseBody)"
            connection.send(content: http.data(using: .utf8), completion: .contentProcessed { _ in })
        }
    }

    private func json(_ body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func queryValue(_ requestLine: String, key: String) -> String? {
        // e.g. "GET /commands?tabId=123 HTTP/1.1"
        let pieces = requestLine.components(separatedBy: " ")
        guard pieces.count >= 2 else { return nil }
        let path = pieces[1]
        guard let query = path.components(separatedBy: "?").dropFirst().first else { return nil }
        for pair in query.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2 && kv[0] == key {
                return kv[1].removingPercentEncoding ?? kv[1]
            }
        }
        return nil
    }
}
