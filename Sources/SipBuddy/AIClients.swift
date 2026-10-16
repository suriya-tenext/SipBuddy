import Foundation

struct AIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

typealias JSON = [String: Any]

private func postJSON(_ request: URLRequest) async throws -> JSON {
    let (data, response) = try await URLSession.shared.data(for: request)
    let json = (try? JSONSerialization.jsonObject(with: data)) as? JSON ?? [:]
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else {
        let message = (json["error"] as? JSON)?["message"] as? String
        throw AIError(message: message ?? "HTTP \(status)")
    }
    return json
}

// MARK: - Claude (raw HTTP: there is no official Swift SDK)

/// Claude is the brain: art director, sprite QA, line writer, and chat partner.
struct Claude {
    static let model = "claude-opus-5-5"
    let apiKey: String

    static func image(_ png: Data) -> JSON {
        ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": png.base64EncodedString()]]
    }

    static func text(_ s: String) -> JSON { ["type": "text", "text": s] }

    static func textOf(_ response: JSON) -> String {
        ((response["content"] as? [JSON]) ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
    }

    /// One Messages API call. `effort` trades depth for speed: high for design work, low for quick lines.
    func send(system: String? = nil, messages: [JSON], tools: [JSON]? = nil, schema: JSON? = nil,
              effort: String, maxTokens: Int = 16000) async throws -> JSON {
        var body: JSON = [
            "model": Self.model,
            "max_tokens": maxTokens,
            "messages": messages,
            // If a safety classifier declines, let the API retry on its recommended fallback model.
            "fallbacks": "default",
        ]
        var outputConfig: JSON = ["effort": effort]
        if let schema { outputConfig["format"] = ["type": "json_schema", "schema": schema] }
        body["output_config"] = outputConfig
        if let system { body["system"] = system }
        if let tools { body["tools"] = tools }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let response = try await postJSON(request)
        if response["stop_reason"] as? String == "refusal" {
            throw AIError(message: "Claude declined this request.")
        }
        return response
    }

    /// Single-turn call that returns JSON matching `schema` (structured outputs).
    func structured(system: String, content: [JSON], schema: JSON, effort: String) async throws -> JSON {
        let response = try await send(system: system, messages: [["role": "user", "content": content]],
                                      schema: schema, effort: effort)
        let text = Self.textOf(response)
        guard let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? JSON
        else { throw AIError(message: "Claude returned malformed JSON.") }
        return json
    }
}

/// Builds strict JSON schemas tersely (structured outputs require additionalProperties: false).
enum Schema {
    static let string: JSON = ["type": "string"]
    static let integer: JSON = ["type": "integer"]
    static let boolean: JSON = ["type": "boolean"]
    static func array(_ items: JSON) -> JSON { ["type": "array", "items": items] }
    static func nullable(_ s: JSON) -> JSON { ["anyOf": [s, ["type": "null"]]] }
    static func object(_ props: [String: JSON]) -> JSON {
        ["type": "object", "properties": props, "required": Array(props.keys).sorted(), "additionalProperties": false]
    }
}

// MARK: - OpenAI images (the painter)

enum ImageAPI {
    /// Generates a PNG. `references` are passed as input images (selfie, hero sheet) for likeness/consistency.
    static func create(prompt: String, references: [Data], size: String, apiKey: String, model: String) async throws -> Data {
        do {
            return try await call(prompt: prompt, references: references, size: size, apiKey: apiKey, model: model, transparent: true)
        } catch let error as AIError where error.message.lowercased().contains("background")
                                       || error.message.lowercased().contains("transparen") {
            // Transparent output is still preview on some models: fall back to a flat key color we strip ourselves.
            let keyed = prompt + "\nBackground: one flat solid pure magenta (#FF00FF) color filling the whole canvas; do not use magenta anywhere on the character."
            return try await call(prompt: keyed, references: references, size: size, apiKey: apiKey, model: model, transparent: false)
        }
    }

    private static func call(prompt: String, references: [Data], size: String, apiKey: String,
                             model: String, transparent: Bool) async throws -> Data {
        var request: URLRequest
        let background = transparent ? "transparent" : "opaque"

        if references.isEmpty {
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/images/generations")!)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model, "prompt": prompt, "size": size, "background": background,
                "quality": "high", "output_format": "png",
            ])
        } else {
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/images/edits")!)
            let boundary = "SipBuddy-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            func field(_ name: String, _ value: String) {
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            for (k, v) in ["model": model, "prompt": prompt, "size": size, "background": background,
                           "quality": "high", "output_format": "png"] {
                field(k, v)
            }
            for (i, png) in references.enumerated() {
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image[]\"; filename=\"ref\(i).png\"\r\nContent-Type: image/png\r\n\r\n".utf8))
                body.append(png)
                body.append(Data("\r\n".utf8))
            }
            body.append(Data("--\(boundary)--\r\n".utf8))
            request.httpBody = body
        }

        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let json = try await postJSON(request)
        guard let first = (json["data"] as? [JSON])?.first,
              let b64 = first["b64_json"] as? String,
              let png = Data(base64Encoded: b64)
        else { throw AIError(message: "The image API returned no image.") }
        return png
    }
}
