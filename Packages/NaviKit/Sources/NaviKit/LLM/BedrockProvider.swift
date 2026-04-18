import CryptoKit
import Foundation

// MARK: - BedrockProvider

struct BedrockProvider: LLMProvider {
    var accessKeyID: String
    var secretAccessKey: String
    var sessionToken: String?
    var region: String
    var modelID: String

    func stream(request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await performRequest(request: request, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private extension BedrockProvider {
    func performRequest(
        request: LLMRequest,
        continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) async throws {
        let trimmedAccess = accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRegion = region.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedAccess.isEmpty, !trimmedSecret.isEmpty else {
            throw BedrockError.invalidConfiguration("Missing AWS access key or secret key.")
        }
        guard !trimmedRegion.isEmpty else {
            throw BedrockError.invalidConfiguration("Missing AWS region.")
        }

        let resolvedModelID = request.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? modelID : request.model
        guard !resolvedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BedrockError.invalidConfiguration("Missing Bedrock model ID.")
        }

        let host = "bedrock-runtime.\(trimmedRegion).amazonaws.com"
        let encodedModelID = resolvedModelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? resolvedModelID
        guard let url = URL(string: "https://\(host)/model/\(encodedModelID)/converse") else {
            throw BedrockError.invalidConfiguration("Invalid Bedrock URL.")
        }

        let bodyObject = try buildBody(from: request)
        let bodyData = try JSONSerialization.data(withJSONObject: bodyObject)

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = bodyData
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        try signRequest(
            &urlRequest,
            bodyData: bodyData,
            host: host,
            region: trimmedRegion,
            accessKeyID: trimmedAccess,
            secretAccessKey: trimmedSecret,
            sessionToken: sessionToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BedrockError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw BedrockError.apiError(status: httpResponse.statusCode, body: body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BedrockError.invalidResponse
        }

        if let usage = json["usage"] as? [String: Any] {
            continuation.yield(
                .usage(
                    input: usage["inputTokens"] as? Int ?? 0,
                    output: usage["outputTokens"] as? Int ?? 0
                )
            )
        }

        let output = json["output"] as? [String: Any]
        let message = output?["message"] as? [String: Any]
        let content = message?["content"] as? [[String: Any]] ?? []

        for block in content {
            if let text = block["text"] as? String, !text.isEmpty {
                continuation.yield(.textDelta(text))
            }

            if let toolUse = block["toolUse"] as? [String: Any],
               let toolUseID = toolUse["toolUseId"] as? String,
               let name = toolUse["name"] as? String
            {
                let input = (toolUse["input"] as? [String: Any]) ?? [:]
                continuation.yield(.toolCall(id: toolUseID, name: name, arguments: input.mapValues(JSONValue.from(any:))))
            }
        }

        let stopRaw = (json["stopReason"] as? String) ?? "end_turn"
        let stopReason = LLMStopReason(rawValue: stopRaw) ?? {
            switch stopRaw {
            case "tool_use": .toolUse
            case "max_tokens": .maxTokens
            default: .endTurn
            }
        }()

        continuation.yield(.done(stopReason: stopReason))
        continuation.finish()
    }

    func buildBody(from request: LLMRequest) throws -> [String: Any] {
        var body: [String: Any] = [
            "messages": convertMessages(request.messages),
            "inferenceConfig": [
                "maxTokens": request.maxTokens,
            ],
        ]

        if !request.systemPrompt.isEmpty {
            body["system"] = [["text": request.systemPrompt]]
        }

        if !request.tools.isEmpty {
            body["toolConfig"] = [
                "tools": request.tools.map { tool in
                    [
                        "toolSpec": [
                            "name": tool.name,
                            "description": tool.description,
                            "inputSchema": [
                                "json": tool.parameters.asJSONObject() ?? [:],
                            ],
                        ],
                    ]
                },
            ]
        }

        return body
    }

    func convertMessages(_ messages: [LLMMessage]) -> [[String: Any]] {
        messages.compactMap { message in
            let content = message.content.compactMap { block -> [String: Any]? in
                switch block {
                case let .text(value):
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : ["text": trimmed]

                case let .thinking(value, _):
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : ["text": trimmed]

                case let .toolCall(id, name, arguments):
                    return [
                        "toolUse": [
                            "toolUseId": id,
                            "name": name,
                            "input": arguments.asJSONObject() ?? [:],
                        ],
                    ]

                case let .toolResult(toolCallID, content, isError):
                    return [
                        "toolResult": [
                            "toolUseId": toolCallID,
                            "content": [["text": content]],
                            "status": isError ? "error" : "success",
                        ],
                    ]
                }
            }

            guard !content.isEmpty else { return nil }
            return [
                "role": message.role == .assistant ? "assistant" : "user",
                "content": content,
            ]
        }
    }

    func signRequest(
        _ request: inout URLRequest,
        bodyData: Data,
        host: String,
        region: String,
        accessKeyID: String,
        secretAccessKey: String,
        sessionToken: String?
    ) throws {
        let service = "bedrock"
        let now = Date()
        let amzDate = now.awsAmzDate
        let dateStamp = now.awsDateStamp
        let payloadHash = bodyData.sha256Hex

        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

        if let sessionToken, !sessionToken.isEmpty {
            request.setValue(sessionToken, forHTTPHeaderField: "x-amz-security-token")
        }

        let canonicalURI = request.url?.path.isEmpty == false ? request.url!.path : "/"
        let canonicalQuery = request.url?.query ?? ""

        var canonicalHeaders: [(String, String)] = [
            ("content-type", request.value(forHTTPHeaderField: "Content-Type") ?? "application/json"),
            ("host", host),
            ("x-amz-content-sha256", payloadHash),
            ("x-amz-date", amzDate),
        ]
        if let sessionToken, !sessionToken.isEmpty {
            canonicalHeaders.append(("x-amz-security-token", sessionToken))
        }

        canonicalHeaders.sort { $0.0 < $1.0 }

        let canonicalHeadersString = canonicalHeaders
            .map { "\($0.0):\($0.1.trimmingCharacters(in: .whitespacesAndNewlines))\n" }
            .joined()
        let signedHeaders = canonicalHeaders.map(\.0).joined(separator: ";")

        let canonicalRequest = [
            request.httpMethod ?? "POST",
            canonicalURI,
            canonicalQuery,
            canonicalHeadersString,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            Data(canonicalRequest.utf8).sha256Hex,
        ].joined(separator: "\n")

        let signingKey = try signatureKey(secretAccessKey: secretAccessKey, dateStamp: dateStamp, region: region, service: service)
        let signature = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: SymmetricKey(data: signingKey)).hexString

        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    func signatureKey(secretAccessKey: String, dateStamp: String, region: String, service: String) throws -> Data {
        let key = Data(("AWS4" + secretAccessKey).utf8)
        let kDate = hmacSHA256(data: Data(dateStamp.utf8), key: key)
        let kRegion = hmacSHA256(data: Data(region.utf8), key: kDate)
        let kService = hmacSHA256(data: Data(service.utf8), key: kRegion)
        return hmacSHA256(data: Data("aws4_request".utf8), key: kService)
    }

    func hmacSHA256(data: Data, key: Data) -> Data {
        let signature = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(signature)
    }
}

private extension JSONValue {
    static func from(any: Any) -> JSONValue {
        switch any {
        case let value as JSONValue:
            value
        case let value as String:
            .string(value)
        case let value as Bool:
            .bool(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                .bool(value.boolValue)
            } else {
                .number(value.doubleValue)
            }
        case let value as [Any]:
            .array(value.map { from(any: $0) })
        case let value as [String: Any]:
            .object(value.mapValues { from(any: $0) })
        default:
            .null
        }
    }

    func asJSONObject() -> Any? {
        switch self {
        case let .string(v): v
        case let .number(v): v
        case let .bool(v): v
        case .null: NSNull()
        case let .array(v): v.map { $0.asJSONObject() ?? NSNull() }
        case let .object(v): v.mapValues { $0.asJSONObject() ?? NSNull() }
        }
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func asJSONObject() -> [String: Any] {
        mapValues { $0.asJSONObject() ?? NSNull() }
    }
}

private extension Data {
    var sha256Hex: String {
        let digest = SHA256.hash(data: self)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}

private extension HMAC<SHA256>.MAC {
    var hexString: String {
        Data(self).map { String(format: "%02x", $0) }.joined()
    }
}

private extension Date {
    var awsAmzDate: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: self)
    }

    var awsDateStamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: self)
    }
}

enum BedrockError: LocalizedError {
    case invalidConfiguration(String)
    case invalidResponse
    case apiError(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message):
            message
        case .invalidResponse:
            "Invalid response from Bedrock API."
        case let .apiError(status, body):
            "Bedrock API error (\(status)): \(body.prefix(500))"
        }
    }
}
