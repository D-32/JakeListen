// GeminiClient — talks to the Google Gemini API directly from the app.
// Audio goes straight from this Mac to Google under the user's own key; there is
// no JakeListen server in between. See https://ai.google.dev/gemini-api/docs/audio
//
// Files are uploaded with the resumable File API (works for any length), then
// referenced by URI in a generateContent call.

import Foundation

struct GeminiClient {
    let apiKey: String
    private let base = "https://generativelanguage.googleapis.com"

    private var session: URLSession {
        let cfg = URLSessionConfiguration.default
        // Transcribing a long meeting can take several minutes.
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 1200
        return URLSession(configuration: cfg)
    }

    struct UploadedFile { let uri: String; let mimeType: String }

    enum GeminiError: LocalizedError {
        case http(String, Int, String)
        case noUploadURL
        case notActive(String)
        case emptyResponse
        var errorDescription: String? {
            switch self {
            case .http(let what, let code, let body):
                return "\(what) failed (\(code)): \(body.prefix(300))"
            case .noUploadURL:  return "Gemini did not return an upload URL."
            case .notActive(let s): return "Uploaded file never became active (state=\(s))."
            case .emptyResponse: return "Gemini returned an empty response."
            }
        }
    }

    // MARK: - File upload (resumable)

    func upload(fileURL: URL) async throws -> UploadedFile {
        let bytes = try Data(contentsOf: fileURL)
        let mime = Self.mime(for: fileURL)

        // 1) Start the resumable session.
        var startReq = URLRequest(url: URL(string: "\(base)/upload/v1beta/files?key=\(apiKey)")!)
        startReq.httpMethod = "POST"
        startReq.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        startReq.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        startReq.setValue(String(bytes.count), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        startReq.setValue(mime, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        startReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        startReq.httpBody = try JSONSerialization.data(
            withJSONObject: ["file": ["display_name": fileURL.lastPathComponent]])

        let (startData, startResp) = try await session.data(for: startReq)
        let startHTTP = startResp as! HTTPURLResponse
        guard (200..<300).contains(startHTTP.statusCode) else {
            throw GeminiError.http("Upload start", startHTTP.statusCode, String(decoding: startData, as: UTF8.self))
        }
        guard let uploadURLString = startHTTP.value(forHTTPHeaderField: "x-goog-upload-url"),
              let uploadURL = URL(string: uploadURLString) else {
            throw GeminiError.noUploadURL
        }

        // 2) Upload the bytes and finalize.
        var upReq = URLRequest(url: uploadURL)
        upReq.httpMethod = "POST"
        upReq.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        upReq.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        upReq.httpBody = bytes

        let (upData, upResp) = try await session.data(for: upReq)
        let upHTTP = upResp as! HTTPURLResponse
        guard (200..<300).contains(upHTTP.statusCode) else {
            throw GeminiError.http("Upload", upHTTP.statusCode, String(decoding: upData, as: UTF8.self))
        }
        var file = (try JSONSerialization.jsonObject(with: upData) as? [String: Any])?["file"] as? [String: Any] ?? [:]

        // 3) Wait until the file is ACTIVE (audio is processed server-side first).
        while (file["state"] as? String) == "PROCESSING" {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            guard let name = file["name"] as? String else { break }
            let (d, _) = try await session.data(from: URL(string: "\(base)/v1beta/\(name)?key=\(apiKey)")!)
            file = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? file
        }
        let state = file["state"] as? String ?? "UNKNOWN"
        guard state == "ACTIVE", let uri = file["uri"] as? String else {
            throw GeminiError.notActive(state)
        }
        return UploadedFile(uri: uri, mimeType: file["mimeType"] as? String ?? mime)
    }

    // MARK: - generateContent

    /// A single content part. `text` or `fileData` (uploaded audio).
    static func textPart(_ s: String) -> [String: Any] { ["text": s] }
    static func filePart(_ f: UploadedFile) -> [String: Any] {
        ["file_data": ["mime_type": f.mimeType, "file_uri": f.uri]]
    }

    func generate(model: String, parts: [[String: Any]],
                  temperature: Double? = nil, allowEmpty: Bool = false) async throws -> String {
        var body: [String: Any] = ["contents": [["role": "user", "parts": parts]]]
        if let temperature { body["generationConfig"] = ["temperature": temperature] }

        var req = URLRequest(url: URL(string: "\(base)/v1beta/models/\(model):generateContent?key=\(apiKey)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        let http = resp as! HTTPURLResponse
        guard http.statusCode == 200 else {
            throw GeminiError.http("Transcription", http.statusCode, String(decoding: data, as: UTF8.self))
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let candidates = json?["candidates"] as? [[String: Any]]
        let content = candidates?.first?["content"] as? [String: Any]
        let outParts = content?["parts"] as? [[String: Any]]
        let text = (outParts?.compactMap { $0["text"] as? String }.joined() ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && !allowEmpty { throw GeminiError.emptyResponse }
        return text
    }

    private static func mime(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4": return "audio/mp4"
        case "wav":        return "audio/wav"
        case "mp3":        return "audio/mp3"
        case "aac":        return "audio/aac"
        case "flac":       return "audio/flac"
        case "ogg":        return "audio/ogg"
        default:           return "audio/mp4"
        }
    }
}
