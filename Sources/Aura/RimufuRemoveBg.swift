import AppKit

/// Remove-background client for the deployed Rimufu API, used by the
/// Aura "Remove BG" section (IslandView). The server does the heavy
/// work (rembg/u2netp); Aura only uploads the image and shows the
/// PNG it gets back, so a Mac without a GPU can still use it.
///
/// Backend: the VPS deploy at zcal.my.id (see the Rimufu deploy
/// notes). That VPS is temporary and will not be renewed: when the
/// backend moves, change `baseURL` below and nothing else — the
/// section, the divider, and Save all go through this one constant.
/// The API has no auth, so anyone who knows the URL can use it.
/// Model options for Remove BG, using the web UI's labels
/// (Quality/Balanced/Fast) with the API values behind them.
/// Default is Fast (u2netp): the current behavior, and the only
/// model the 1 GB VPS deploy is known to run (see the comment
/// on removeBackground).
enum RemoveBgModel: String, CaseIterable {
    case quality = "birefnet-general"
    case balanced = "u2net"
    case fast = "u2netp"

    var apiValue: String { rawValue }

    var displayName: String {
        switch self {
        case .quality: return "Quality"
        case .balanced: return "Balanced"
        case .fast: return "Fast"
        }
    }
}

enum RimufuRemoveBgError: Error {
    case invalidImage
    case uploadFailed(String)
    case serverError(String)
    case invalidResponse

    var message: String {
        switch self {
        case .invalidImage: return "Could not read that image."
        case .uploadFailed(let detail): return detail
        case .serverError(let detail): return detail
        case .invalidResponse: return "Server returned an image Aura could not read."
        }
    }
}

final class RimufuRemoveBgClient {
    /// Single backend base URL for the whole feature. The API path
    /// is /api/remove-bg; nginx strips the /rimufu-api prefix, so
    /// this full public URL is the API root, not the web root.
    static let baseURL = "https://zcal.my.id/rimufu-api"

    /// Upload limits, chosen for the 1 GB VPS: the server forces
    /// u2netp (light), but decoding a huge input still costs RAM,
    /// and nginx caps bodies at 30 MB. Images over either limit are
    /// downscaled to JPEG before upload (see preparedUploadData);
    /// smaller images go up untouched, so there is no quality loss
    /// in the normal case.
    static let maxSidePixels = 2000
    static let maxUploadBytes = 10 * 1024 * 1024

    /// Pixel size of an NSImage, from its representations when
    /// available (size is in points, which understates @2x images).
    static func pixelSize(of image: NSImage) -> NSSize {
        var width = 0
        var height = 0
        for rep in image.representations {
            width = max(width, rep.pixelsWide)
            height = max(height, rep.pixelsHigh)
        }
        if width > 0 && height > 0 { return NSSize(width: width, height: height) }
        return image.size
    }

    /// Prepare upload bytes for an image. Small images return their
    /// original file data unchanged. Oversize images are resized to
    /// maxSidePixels (aspect preserved) and encoded as JPEG 0.92:
    /// input transparency is irrelevant here — the server recomputes
    /// the alpha channel — so JPEG is safe for the resized path.
    static func preparedUploadData(image: NSImage, originalData: Data, originalName: String) -> (data: Data, fileName: String, mimeType: String) {
        let pixels = pixelSize(of: image)
        let maxSide = max(pixels.width, pixels.height)
        if maxSide <= CGFloat(maxSidePixels) && originalData.count <= maxUploadBytes {
            return (originalData, originalName, mimeType(for: originalName))
        }
        let scale = CGFloat(maxSidePixels) / maxSide
        let newSize = NSSize(width: pixels.width * scale, height: pixels.height * scale)
        let resized = NSImage(size: newSize)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize), from: .zero,
                   operation: .sourceOver, fraction: 1.0)
        resized.unlockFocus()
        if let tiff = resized.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) {
            let base = (originalName as NSString).deletingPathExtension
            return (jpeg, base + ".jpg", "image/jpeg")
        }
        // Resize/encode failed: send the original and let the
        // server decide, rather than failing the whole action.
        return (originalData, originalName, mimeType(for: originalName))
    }

    static func mimeType(for fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        default: return "application/octet-stream"
        }
    }

    /// POST /api/remove-bg?model=<model>. The deployed VPS
    /// server currently forces u2netp regardless of the parameter
    /// (deploy-only patch, after u2net OOMed on 1 GB), so on that
    /// server every model choice still returns a u2netp result
    /// until the patch is removed — the parameter is sent honestly
    /// so the picker works as soon as the server allows it.
    /// Completion runs on the URLSession queue, not the main
    /// thread — the caller must hop to main before touching UI.
    /// The returned task can be cancelled when the user picks
    /// another image mid-upload, so a stale result never overwrites
    /// the new one.
    @discardableResult
    static func removeBackground(data: Data, fileName: String, mimeType: String, model: RemoveBgModel,
                                 completion: @escaping (Result<Data, RimufuRemoveBgError>) -> Void) -> URLSessionDataTask? {
        let urlString = baseURL + "/api/remove-bg?model=\(model.apiValue)&alpha_matting=false"
        guard let url = URL(string: urlString) else {
            completion(.failure(.serverError("Remove BG backend URL is invalid.")))
            return nil
        }
        let boundary = "Aura-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 180
        let task = URLSession.shared.dataTask(with: request) { responseData, response, error in
            if let error = error as? URLError, error.code == .cancelled {
                completion(.failure(.uploadFailed("Cancelled.")))
                return
            }
            if let error {
                completion(.failure(.uploadFailed("Could not reach the server: \(error.localizedDescription)")))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(.uploadFailed("No response from the server.")))
                return
            }
            guard http.statusCode == 200, let responseData else {
                completion(.failure(.serverError(serverMessage(from: responseData, status: http.statusCode))))
                return
            }
            // The API returns PNG on success; nginx errors return
            // HTML. Checking the PNG magic keeps an HTML error page
            // from being treated as an image.
            let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            guard responseData.count > pngMagic.count,
                  Array(responseData.prefix(pngMagic.count)) == pngMagic else {
                completion(.failure(.invalidResponse))
                return
            }
            completion(.success(responseData))
        }
        task.resume()
        return task
    }

    /// Best-effort error text from a non-200 body: the API returns
    /// {"detail": ...} or {"error": ...}; anything else falls back
    /// to the HTTP status so the card never shows a blank error.
    private static func serverMessage(from data: Data?, status: Int) -> String {
        if let data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = json["detail"] as? String, !detail.isEmpty { return detail }
            if let error = json["error"] as? String, !error.isEmpty { return error }
        }
        return "Server error (HTTP \(status))."
    }

    /// Unique destination in ~/Downloads/Aura, Finder-style
    /// numbering ("Remove BG.png", "Remove BG 2.png", ...). Mirrors
    /// the LAN share numbering so saved results never overwrite
    /// each other or a LAN-received file.
    static func uniqueDownloadURL(fileName: String) -> URL? {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Aura")
        guard let dir = downloads else { return nil }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let ext = (fileName as NSString).pathExtension
        let base = (fileName as NSString).deletingPathExtension
        var candidate = dir.appendingPathComponent(fileName)
        var i = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            candidate = dir.appendingPathComponent(numbered)
            i += 1
        }
        return candidate
    }
}
