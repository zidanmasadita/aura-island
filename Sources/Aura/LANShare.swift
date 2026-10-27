import Foundation
import Darwin

/// A discovered Aura peer on the local network (another device
/// running Aura). Address is the sender's IP as seen by us (from
/// recvfrom), port is its HTTP receive port from its announce.
struct LANPeer: Equatable {
    let id: String
    let name: String
    let address: String
    let port: UInt16
    var lastSeen: Date
}

/// Aura-to-Aura LAN sharing (the cross-platform path: AirDrop is
/// Apple-only, so this protocol is stack-agnostic — UDP broadcast
/// discovery + plain HTTP transfer, no Apple-only APIs — so a
/// future Windows Aura can implement the same protocol and
/// interoperate). Same-network only (broadcast domain), receiver
/// approval required, one-time tokens, plaintext HTTP on a trusted
/// LAN (TLS is a follow-up, like LocalSend's self-signed certs).
/// All peer/bookkeeping state lives on the main thread; connection
/// threads only parse and respond (tokens behind a lock).
final class LANShare {
    /// UDP discovery port (Aura's extension bridge is 48123).
    private let discoveryPort: UInt16 = 48124
    /// HTTP receive ports tried in order (first that binds wins).
    private let httpPorts: [UInt16] = [48125, 48126, 48127, 48128, 48129, 48130]
    /// How long a peer stays listed without a fresh announce.
    private let peerTTL: TimeInterval = 10
    /// How often we announce ourselves.
    private let announceInterval: TimeInterval = 2
    /// How long a share request waits for approval.
    private let requestTimeout: TimeInterval = 60
    /// How long a file upload may stall mid-transfer.
    private let uploadStallTimeout: TimeInterval = 300

    /// Called on the main thread whenever the peer list changes.
    var onPeersChanged: (([LANPeer]) -> Void)?

    private let ownID: String
    private let ownName: String
    private var httpPort: UInt16?
    private var peers: [String: LANPeer] = [:]
    private var pendingTokens: [String: PendingTransfer] = [:]
    private let tokenLock = NSLock()
    private var announceTimer: Timer?
    /// Send generation: bumped on cancel/new send so late callbacks
    /// from an abandoned send never touch UI or bookkeeping.
    /// Main thread only (all send/cancel/completion paths hop to main).
    private var sendGeneration = 0
    private var currentSendTasks: [URLSessionTask] = []
    private var currentSendSessions: [URLSession] = []

    private struct PendingTransfer {
        let fileName: String
        let fileSize: Int64
    }

    private struct Announce: Codable {
        let type: String
        let id: String
        let name: String
        let port: UInt16
    }

    init() {
        if let saved = UserDefaults.standard.string(forKey: "AuraPeerID") {
            ownID = saved
        } else {
            ownID = UUID().uuidString
            UserDefaults.standard.set(ownID, forKey: "AuraPeerID")
        }
        ownName = Host.current().localizedName ?? "Mac"
    }

    /// Start discovery listener, HTTP receiver, and periodic
    /// announce. If no HTTP port binds, receiving is off (we can
    /// still send) and no announce is sent (peers could not reach us).
    /// Call on the main thread (the announce timer is main).
    func start() {
        startUDPListener()
        if startHTTPServer() {
            sendAnnounce()
            announceTimer = Timer.scheduledTimer(withTimeInterval: announceInterval, repeats: true) { [weak self] _ in
                self?.sendAnnounce()
                self?.pruneStalePeers()
            }
        } else {
            print("[Aura] LAN receive unavailable (no HTTP port)")
        }
    }

    /// Peers heard from within peerTTL, sorted by name (stable UI).
    /// Main thread only.
    private func currentPeers() -> [LANPeer] {
        let cutoff = Date().addingTimeInterval(-peerTTL)
        return peers.values.filter { $0.lastSeen >= cutoff }.sorted { $0.name < $1.name }
    }

    private func pruneStalePeers() {
        let before = peers.count
        let cutoff = Date().addingTimeInterval(-peerTTL)
        peers = peers.filter { $0.value.lastSeen >= cutoff }
        if peers.count != before {
            onPeersChanged?(currentPeers())
        }
    }

    // MARK: - UDP discovery

    private func startUDPListener() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return }
            var reuse: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = self.discoveryPort.bigEndian
            addr.sin_addr = in_addr(s_addr: 0)
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { close(fd); return }
            var buffer = [UInt8](repeating: 0, count: 2048)
            while true {
                var sender = sockaddr_storage()
                var senderLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let n = withUnsafeMutablePointer(to: &sender) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, &buffer, buffer.count, 0, $0, &senderLen)
                    }
                }
                guard n > 0 else { continue }
                let data = Data(buffer[0..<n])
                guard let announce = try? JSONDecoder().decode(Announce.self, from: data),
                      announce.type == "aura-hello", announce.id != self.ownID else { continue }
                var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var address = ""
                withUnsafePointer(to: &sender) {
                    $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                        var sinAddr = sin.pointee.sin_addr
                        address = inet_ntop(AF_INET, &sinAddr, &ipBuffer, socklen_t(ipBuffer.count)).map { String(cString: $0) } ?? ""
                    }
                }
                guard !address.isEmpty else { continue }
                let peer = LANPeer(id: announce.id, name: announce.name, address: address, port: announce.port, lastSeen: Date())
                DispatchQueue.main.async {
                    self.peers[peer.id] = peer
                    self.pruneStalePeers()
                    self.onPeersChanged?(self.currentPeers())
                }
            }
        }
    }

    private func sendAnnounce() {
        guard let port = httpPort else { return }
        let announce = Announce(type: "aura-hello", id: ownID, name: ownName, port: port)
        guard let data = try? JSONEncoder().encode(announce) else { return }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var broadcast: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = discoveryPort.bigEndian
        addr.sin_addr = in_addr(s_addr: 0xFFFFFFFF)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(fd, base, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    // MARK: - HTTP receiver

    /// Bind the first free HTTP port and start the accept loop on a
    /// background thread. Returns true if a port bound.
    private func startHTTPServer() -> Bool {
        for port in httpPorts {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            var reuse: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr = in_addr(s_addr: 0)
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { close(fd); continue }
            guard listen(fd, 8) == 0 else { close(fd); continue }
            httpPort = port
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.acceptLoop(serverFD: fd)
            }
            print("[Aura] LAN receive on port \(port)")
            return true
        }
        return false
    }

    private func acceptLoop(serverFD: Int32) {
        while true {
            let client = accept(serverFD, nil, nil)
            guard client >= 0 else { continue }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.handleConnection(client)
                close(client)
            }
        }
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let bodyPrefix: Data
        let contentLength: Int
    }

    private func handleConnection(_ fd: Int32) {
        guard let request = readHTTPRequest(fd: fd) else { return }
        switch (request.method, request.path) {
        case ("POST", "/aura-share/request"):
            // Small JSON body: read it fully, then approve.
            var body = request.bodyPrefix
            if request.contentLength > body.count {
                var rest = Data()
                guard readExactly(fd: fd, count: request.contentLength - body.count, write: { rest.append($0) }) else { return }
                body.append(rest)
            }
            handleShareRequest(fd: fd, body: body)
        case ("POST", "/aura-share/file"):
            handleShareFile(fd: fd, headers: request.headers, bodyPrefix: request.bodyPrefix, contentLength: request.contentLength)
        default:
            sendHTTP(fd: fd, status: 404, json: ["ok": false, "error": "unknown path"])
        }
    }

    /// Read until headers end (\r\n\r\n). Returns nil on EOF/error
    /// or oversize headers. Bytes already read past the headers are
    /// returned as bodyPrefix (the caller accounts for them, so a
    /// small body that arrived with the headers is not lost).
    private func readHTTPRequest(fd: Int32) -> HTTPRequest? {
        var buffer = Data()
        let crlfcrlf = Data([13, 10, 13, 10])
        while buffer.count < 16384 {
            if let range = buffer.range(of: crlfcrlf) {
                let headerData = buffer.subdata(in: 0..<range.lowerBound)
                let bodyPrefix = buffer.subdata(in: range.upperBound..<buffer.count)
                guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
                let lines = headerText.components(separatedBy: "\r\n")
                guard let requestLine = lines.first else { return nil }
                let parts = requestLine.split(separator: " ")
                guard parts.count >= 2 else { return nil }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    headers[key] = value
                }
                let contentLength = Int(headers["content-length"] ?? "0") ?? 0
                return HTTPRequest(method: String(parts[0]), path: String(parts[1]),
                                   headers: headers, bodyPrefix: bodyPrefix, contentLength: max(0, contentLength))
            }
            var byte: UInt8 = 0
            let n = recv(fd, &byte, 1, 0)
            guard n == 1 else { return nil }
            buffer.append(byte)
        }
        return nil
    }

    /// Read exactly `count` bytes, calling write per chunk. False on EOF/error.
    private func readExactly(fd: Int32, count: Int, write: (Data) -> Void) -> Bool {
        var remaining = count
        var chunk = [UInt8](repeating: 0, count: 65536)
        while remaining > 0 {
            let want = min(remaining, chunk.count)
            let n = recv(fd, &chunk, want, 0)
            guard n > 0 else { return false }
            write(Data(chunk[0..<n]))
            remaining -= n
        }
        return true
    }

    private func sendAll(fd: Int32, data: Data) {
        var offset = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < data.count {
                let n = send(fd, base.advanced(by: offset), data.count - offset, 0)
                guard n > 0 else { return }
                offset += n
            }
        }
    }

    private func sendHTTP(fd: Int32, status: Int, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        let reason = status == 200 ? "OK" : status == 400 ? "Bad Request" : status == 403 ? "Forbidden" : status == 404 ? "Not Found" : "Error"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(body)
        sendAll(fd: fd, data: response)
    }

    private func formatSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / 1048576.0) }
        return String(format: "%.1f GB", Double(bytes) / 1073741824.0)
    }

    private func handleShareRequest(fd: Int32, body: Data) {
        struct Request: Codable { let senderName: String; let senderId: String; let fileName: String; let fileSize: Int64 }
        guard let req = try? JSONDecoder().decode(Request.self, from: body) else {
            sendHTTP(fd: fd, status: 400, json: ["ok": false, "error": "bad request"])
            return
        }
        // Approval on the main thread (NSAlert is main-only). This
        // connection thread blocks here; other connections are
        // unaffected (each has its own thread).
        let accepted = DispatchQueue.main.sync {
            let alert = NSAlert()
            alert.messageText = "Permintaan Berbagi"
            alert.informativeText = "\(req.senderName) ingin mengirim '\(req.fileName)' (\(formatSize(req.fileSize))). Terima file ini?"
            alert.addButton(withTitle: "Terima")
            alert.addButton(withTitle: "Tolak")
            return alert.runModal() == .alertFirstButtonReturn
        }
        guard accepted else {
            sendHTTP(fd: fd, status: 200, json: ["ok": true, "accepted": false])
            return
        }
        let token = UUID().uuidString
        tokenLock.lock()
        pendingTokens[token] = PendingTransfer(fileName: req.fileName, fileSize: req.fileSize)
        tokenLock.unlock()
        sendHTTP(fd: fd, status: 200, json: ["ok": true, "accepted": true, "token": token])
    }

    private func handleShareFile(fd: Int32, headers: [String: String], bodyPrefix: Data, contentLength: Int) {
        // Token first, before reading the body: an unsolicited
        // upload never touches the disk.
        guard let token = headers["x-aura-token"] else {
            sendHTTP(fd: fd, status: 403, json: ["ok": false, "error": "missing token"])
            return
        }
        tokenLock.lock()
        let pending = pendingTokens.removeValue(forKey: token)
        tokenLock.unlock()
        guard let pending else {
            sendHTTP(fd: fd, status: 403, json: ["ok": false, "error": "invalid token"])
            return
        }
        let downloads = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads").appendingPathComponent("Aura")
        do {
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        } catch {
            sendHTTP(fd: fd, status: 500, json: ["ok": false, "error": "cannot create folder"])
            return
        }
        let dest = uniqueURL(in: downloads, name: pending.fileName)
        guard FileManager.default.createFile(atPath: dest.path, contents: nil) else {
            sendHTTP(fd: fd, status: 500, json: ["ok": false, "error": "cannot create file"])
            return
        }
        guard let handle = try? FileHandle(forWritingTo: dest) else {
            sendHTTP(fd: fd, status: 500, json: ["ok": false, "error": "cannot open file"])
            return
        }
        defer { try? handle.close() }
        var remaining = contentLength
        var prefix = bodyPrefix
        if prefix.count > remaining { prefix = prefix.prefix(remaining) }
        if !prefix.isEmpty {
            handle.write(prefix)
            remaining -= prefix.count
        }
        if remaining > 0 {
            let ok = readExactly(fd: fd, count: remaining) { chunk in handle.write(chunk) }
            if !ok {
                try? FileManager.default.removeItem(at: dest)
                return // connection died; nothing to respond to
            }
        }
        sendHTTP(fd: fd, status: 200, json: ["ok": true])
    }

    /// Dedupe like Finder: "name 1.ext", "name 2.ext", ...
    private func uniqueURL(in dir: URL, name: String) -> URL {
        let nsName = name as NSString
        let base = nsName.deletingPathExtension
        let ext = nsName.pathExtension
        var candidate = dir.appendingPathComponent(name)
        var i = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            candidate = dir.appendingPathComponent(numbered)
            i += 1
        }
        return candidate
    }

    // MARK: - Sender

    /// Send one file to a peer: request (approval) then upload.
    /// Progress + completion are called on the main thread.
    /// Call on the main thread (send/cancel/completion bookkeeping
    /// is main-only; the delegate hops to main before touching it).
    func sendFile(to peer: LANPeer, file: URL, progress: @escaping (Double) -> Void, completion: @escaping (String?) -> Void) {
        cancelSend()
        let gen = sendGeneration
        let requestURL = URL(string: "http://\(peer.address):\(peer.port)/aura-share/request")!
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
        let payload: [String: Any] = ["senderName": ownName, "senderId": ownID,
                                      "fileName": file.lastPathComponent, "fileSize": fileSize]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, gen == self.sendGeneration else { return }
                self.currentSendTasks = []
                if let error = error as? URLError, error.code == .timedOut {
                    completion("Waktu habis (tidak ada jawaban)")
                    return
                }
                guard error == nil,
                      let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (json["ok"] as? Bool) == true else {
                    completion("Gagal terhubung")
                    return
                }
                guard (json["accepted"] as? Bool) == true,
                      let token = json["token"] as? String else {
                    completion("Ditolak")
                    return
                }
                self.uploadFile(to: peer, file: file, token: token, gen: gen, progress: progress, completion: completion)
            }
        }
        currentSendTasks = [task]
        task.resume()
    }

    /// Abort the in-flight send (e.g., user taps back). Bumps the
    /// generation so late callbacks from the old send are ignored.
    /// Call on the main thread.
    func cancelSend() {
        sendGeneration += 1
        for task in currentSendTasks { task.cancel() }
        currentSendTasks = []
        currentSendSessions = []
    }

    private func uploadFile(to peer: LANPeer, file: URL, token: String, gen: Int, progress: @escaping (Double) -> Void, completion: @escaping (String?) -> Void) {
        let url = URL(string: "http://\(peer.address):\(peer.port)/aura-share/file")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = uploadStallTimeout
        request.setValue(token, forHTTPHeaderField: "X-Aura-Token")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let delegate = UploadDelegate(
            progress: { fraction in
                DispatchQueue.main.async { [weak self] in
                    guard let self, gen == self.sendGeneration else { return }
                    progress(fraction)
                }
            },
            completion: { [weak self] message in
                DispatchQueue.main.async {
                    guard let self, gen == self.sendGeneration else { return }
                    self.currentSendTasks = []
                    self.currentSendSessions = []
                    completion(message)
                }
            })
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        currentSendSessions = [session]
        let task = session.uploadTask(with: request, fromFile: file)
        currentSendTasks = [task]
        task.resume()
    }

    /// URLSessionDataDelegate for one upload: progress + response body
    /// + completion. Called on the session's background queue; the
    /// closures hop to main (see uploadFile).
    private final class UploadDelegate: NSObject, URLSessionDataDelegate {
        private let progress: (Double) -> Void
        private let completion: (String?) -> Void
        private var responseData = Data()
        private var httpStatus = 0

        init(progress: @escaping (Double) -> Void, completion: @escaping (String?) -> Void) {
            self.progress = progress
            self.completion = completion
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            guard totalBytesExpectedToSend > 0 else { return }
            progress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if let http = response as? HTTPURLResponse { httpStatus = http.statusCode }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            responseData.append(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                if (error as? URLError)?.code == .cancelled {
                    completion("Dibatalkan")
                } else {
                    completion("Gagal mengirim")
                }
                return
            }
            let ok = httpStatus == 200
                && ((try? JSONSerialization.jsonObject(with: responseData) as? [String: Any])?["ok"] as? Bool) == true
            completion(ok ? nil : "Gagal mengirim")
        }
    }
}
