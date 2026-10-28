import AppKit

/// Convert client for the deployed Rimufu API, used by the Aura
/// "Convert" section (IslandView, Fase 1: single-file tools only —
/// photo convert, PDF to Word, PDF compress, PDF to Markdown).
/// Merge PDF is Fase 2 and is not in this file.
///
/// Shares the backend base URL and the Downloads/Aura numbering
/// with RimufuRemoveBgClient (same module, no duplication). The
/// Remove BG client is untouched: this file only adds the
/// multipart shapes Convert needs (a text form field for the
/// photo format, a JSON response for Markdown).
enum RimufuConvertError: Error {
    case uploadFailed(String)
    case serverError(String)
    case invalidResponse

    var message: String {
        switch self {
        case .uploadFailed(let detail): return detail
        case .serverError(let detail): return detail
        case .invalidResponse: return "Server returned a result Aura could not read."
        }
    }
}

enum ConvertFormat: String, CaseIterable {
    case avif, webp, png

    /// Value for the API's format form field. The server treats
    /// anything other than avif/webp as PNG, so "png" is explicit
    /// and safe, not a fallback accident.
    var formValue: String { rawValue }
    var fileExtension: String { rawValue }
    var displayName: String {
        switch self {
        case .avif: return "AVIF"
        case .webp: return "WebP"
        case .png: return "PNG"
        }
    }
}

final class RimufuConvertClient {
    static let baseURL = RimufuRemoveBgClient.baseURL

    /// Multipart body with one file part plus optional text
    /// fields (convert uses one: format). Field order follows the
    /// API's form parsing (file first, then fields — the order
    /// FastAPI reads does not matter, but file-first reads like
    /// the web client's requests).
    private static func multipartBody(fileData: Data, fileName: String, mimeType: String,
                                      fields: [(name: String, value: String)]) -> (body: Data, boundary: String) {
        let boundary = "Aura-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        for field in fields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n".data(using: .utf8)!)
            body.append(field.value.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return (body, boundary)
    }

    /// Shared POST + validation. `validate` checks the success
    /// bytes for the tool (PNG magic, ftypavif, RIFF/WEBP, PK,
    /// %PDF) so an HTML error page behind a 200 can never pass
    /// as a result. Completion runs on the URLSession queue, not
    /// main — the caller hops to main before touching UI. The
    /// returned task can be cancelled when the user starts
    /// another run, so a stale result never overwrites the new one.
    @discardableResult
    private static func post(path: String, fileData: Data, fileName: String, mimeType: String,
                             fields: [(name: String, value: String)] = [],
                             validate: @escaping (Data) -> Bool,
                             completion: @escaping (Result<Data, RimufuConvertError>) -> Void) -> URLSessionDataTask? {
        guard let url = URL(string: baseURL + path) else {
            completion(.failure(.serverError("Convert backend URL is invalid.")))
            return nil
        }
        let (body, boundary) = multipartBody(fileData: fileData, fileName: fileName,
                                             mimeType: mimeType, fields: fields)
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
            guard validate(responseData) else {
                completion(.failure(.invalidResponse))
                return
            }
            completion(.success(responseData))
        }
        task.resume()
        return task
    }

    private static func serverMessage(from data: Data?, status: Int) -> String {
        if let data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = json["detail"] as? String, !detail.isEmpty { return detail }
            if let error = json["error"] as? String, !error.isEmpty { return error }
        }
        return "Server error (HTTP \(status))."
    }

    private static func hasPrefix(_ data: Data, _ bytes: [UInt8]) -> Bool {
        data.count >= bytes.count && Array(data.prefix(bytes.count)) == bytes
    }

    private static func isPNG(_ data: Data) -> Bool {
        hasPrefix(data, [0x89, 0x50, 0x4E, 0x47])
    }

    private static func isWebP(_ data: Data) -> Bool {
        data.count >= 12
            && Array(data.prefix(4)) == Array("RIFF".utf8)
            && Array(data[8..<12]) == Array("WEBP".utf8)
    }

    private static func isAVIF(_ data: Data) -> Bool {
        // Box size (4 bytes), "ftyp" (4), "avif" (4) — verified
        // against the VPS convert output (ftypavif at offset 4).
        data.count >= 12
            && Array(data[4..<8]) == Array("ftyp".utf8)
            && Array(data[8..<12]) == Array("avif".utf8)
    }

    /// POST /api/convert. The format field is required by the
    /// API even though the server falls back to PNG for unknown
    /// values — this always sends a known value.
    @discardableResult
    static func convertImage(data: Data, fileName: String, mimeType: String, format: ConvertFormat,
                             completion: @escaping (Result<Data, RimufuConvertError>) -> Void) -> URLSessionDataTask? {
        let validate: (Data) -> Bool
        switch format {
        case .avif: validate = isAVIF
        case .webp: validate = isWebP
        case .png: validate = isPNG
        }
        return post(path: "/api/convert", fileData: data, fileName: fileName, mimeType: mimeType,
                    fields: [(name: "format", value: format.formValue)],
                    validate: validate, completion: completion)
    }

    /// POST /api/pdf/to-word. A DOCX is a ZIP, so "PK" is the
    /// success check (same idea as the PNG magic in Remove BG).
    @discardableResult
    static func pdfToWord(data: Data, fileName: String,
                          completion: @escaping (Result<Data, RimufuConvertError>) -> Void) -> URLSessionDataTask? {
        post(path: "/api/pdf/to-word", fileData: data, fileName: fileName, mimeType: "application/pdf",
             validate: { hasPrefix($0, Array("PK".utf8)) }, completion: completion)
    }

    /// POST /api/pdf/compress. Success is a PDF again.
    @discardableResult
    static func compressPDF(data: Data, fileName: String,
                            completion: @escaping (Result<Data, RimufuConvertError>) -> Void) -> URLSessionDataTask? {
        post(path: "/api/pdf/compress", fileData: data, fileName: fileName, mimeType: "application/pdf",
             validate: { hasPrefix($0, Array("%PDF".utf8)) }, completion: completion)
    }

    /// POST /api/pdf/to-md. Unlike the other tools this returns
    /// JSON {"result": md_text}, not file bytes — so the success
    /// value here is the markdown text encoded as UTF-8 Data, and
    /// the section treats it like any other result (Save and
    /// drag-out write it as a .md file). An empty result is a
    /// failure, not an empty file: a scanned PDF with no text
    /// layer extracts nothing, and saving that as a blank .md
    /// would look like a broken conversion.
    @discardableResult
    static func pdfToMarkdown(data: Data, fileName: String,
                              completion: @escaping (Result<Data, RimufuConvertError>) -> Void) -> URLSessionDataTask? {
        guard let url = URL(string: baseURL + "/api/pdf/to-md") else {
            completion(.failure(.serverError("Convert backend URL is invalid.")))
            return nil
        }
        let (body, boundary) = multipartBody(fileData: data, fileName: fileName,
                                             mimeType: "application/pdf", fields: [])
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
            guard http.statusCode == 200, let responseData,
                  let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let text = json["result"] as? String else {
                completion(.failure(.serverError(serverMessage(from: responseData, status: http.statusCode))))
                return
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let utf8 = text.data(using: .utf8) else {
                completion(.failure(.serverError("No text found in this PDF.")))
                return
            }
            completion(.success(utf8))
        }
        task.resume()
        return task
    }
}
