import Foundation

// MARK: - VLLMProvider

struct VLLMProvider: LLMProvider {
    var apiKey: String
    var baseURL: String

    func stream(request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await performStream(request: request, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private extension VLLMProvider {
    func performStream(
        request: LLMRequest,
        continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) async throws {
        let httpRequest = try buildHTTPRequest(from: request)
        let (bytes, response) = try await URLSession.shared.bytes(for: httpRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw VLLMError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw VLLMError.apiError(status: httpResponse.statusCode, body: body)
        }

        var toolCallsByIndex: [Int: StreamingToolCall] = [:]
        var sawToolCalls = false

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" {
                continuation.yield(.done(stopReason: sawToolCalls ? .toolUse : .endTurn))
                continuation.finish()
                return
            }

            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let firstChoice = choices.first
            else { continue }

            if let delta = firstChoice["delta"] as? [String: Any] {
                if let text = delta["content"] as? String, !text.isEmpty {
                    continuation.yield(.textDelta(text))
                }

                if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                    sawToolCalls = true
                    for toolDelta in toolCalls {
                        let index = toolDelta["index"] as? Int ?? 0
                        var current = toolCallsByIndex[index] ?? StreamingToolCall()

                        if let id = toolDelta["id"] as? String, !id.isEmpty {
                            current.id = id
                        }

                        if let function = toolDelta["function"] as? [String: Any] {
                            if let name = function["name"] as? String, !name.isEmpty {
                                current.name = name
                            }
                            if let argsDelta = function["arguments"] as? String, !argsDelta.isEmpty {
                                current.arguments += argsDelta
                            }
                        }

                        toolCallsByIndex[index] = current
                    }
                }
            }

            if let finishReason = firstChoice["finish_reason"] as? String,
               finishReason != "null" {
                if finishReason == "tool_calls" {
                    for index in toolCallsByIndex.keys.sorted() {
                        guard let tool = toolCallsByIndex[index],
                              let id = tool.id,
                              let name = tool.name
                        else { continue }

                        continuation.yield(
                            .toolCall(
                                id: id,
                                name: name,
                                arguments: parseJSON(tool.arguments)
                            )
                        )
                    }
                    continuation.yield(.done(stopReason: .toolUse))
                } else {
                    continuation.yield(.done(stopReason: .endTurn))
                }
                continuation.finish()
                return
            }
        }

        continuation.yield(.done(stopReason: sawToolCalls ? .toolUse : .endTurn))
        continuation.finish()
    }

    func buildHTTPRequest(from request: LLMRequest) throws -> URLRequest {
        let normalized = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let path = normalized.hasSuffix("/v1") ? "chat/completions" : "v1/chat/completions"
        guard let url = URL(string: "\(normalized)/\(path)") else {
            throw VLLMError.invalidBaseURL
        }

        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            httpRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let body = buildRequestBody(from: request)
        httpRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return httpRequest
    }

    func buildRequestBody(from request: LLMRequest) -> [String: Any] {
        var body: [String: Any] = [
            "model": request.model,
            "stream": true,
            "messages": buildMessages(from: request.messages),
        ]

        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parameters.asJSONObject() ?? [:],
                    ],
                ] as [String: Any]
            }
            body["tool_choice"] = "auto"
        }

        return body
    }

    func buildMessages(from messages: [LLMMessage]) -> [[String: Any]] {
        var converted: [[String: Any]] = []

        for message in messages {
            switch message.role {
            case .user:
                let text = message.content.compactMap { block -> String? in
                    if case let .text(value) = block { return value }
                    return nil
                }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

                if !text.isEmpty {
                    converted.append(["role": "user", "content": text])
                }

                for block in message.content {
                    if case let .toolResult(toolCallID, content, _) = block {
                        converted.append([
                            "role": "tool",
                            "tool_call_id": toolCallID,
                            "content": content,
                        ])
                    }
                }

            case .assistant:
                let text = message.content.compactMap { block -> String? in
                    if case let .text(value) = block { return value }
                    return nil
                }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

                let toolCalls: [[String: Any]] = message.content.compactMap { block in
                    if case let .toolCall(id, name, arguments) = block {
                        let json = try? JSONSerialization.data(
                            withJSONObject: arguments.mapValues { $0.asJSONObject() ?? NSNull() }
                        )
                        let args = json.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        return [
                            "id": id,
                            "type": "function",
                            "function": [
                                "name": name,
                                "arguments": args,
                            ],
                        ]
                    }
                    return nil
                }

                if !text.isEmpty || !toolCalls.isEmpty {
                    var assistant: [String: Any] = ["role": "assistant"]
                    assistant["content"] = text.isEmpty ? NSNull() : text
                    if !toolCalls.isEmpty {
                        assistant["tool_calls"] = toolCalls
                    }
                    converted.append(assistant)
                }
            }
        }

        return converted
    }
}

private struct StreamingToolCall {
    var id: String?
    var name: String?
    var arguments: String = ""
}

private func parseJSON(_ string: String) -> [String: JSONValue] {
    guard let data = string.data(using: .utf8),
          let obj = try? JSONDecoder().decode([String: JSONValue].self, from: data)
    else { return [:] }
    return obj
}

private extension JSONValue {
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

enum VLLMError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case apiError(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "Invalid vLLM base URL."
        case .invalidResponse:
            "Invalid response from vLLM endpoint."
        case let .apiError(status, body):
            "vLLM API error (\(status)): \(body.prefix(500))"
        }
    }
}
