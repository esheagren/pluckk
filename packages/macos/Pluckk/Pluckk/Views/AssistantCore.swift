import Foundation

// The assistant's plumbing, free of app types: one streaming model turn over either provider
// API, and file tools limited to chosen folders. AssistantEngine drives these.

// MARK: - Provider

enum ProviderKind: String {
    case anthropic          // Claude's Messages API
    case openAICompatible   // /chat/completions: Kimi, OpenRouter, Ollama, LM Studio…
}

struct ProviderConfig {
    let kind: ProviderKind
    let baseURL: String
    let model: String
    let apiKey: String
}

struct ToolSpec {
    let name: String
    let description: String
    let schema: [String: Any]
}

struct ToolCall {
    let id: String
    let name: String
    /// Raw JSON. With streamed tool input this can be incomplete, so executors must parse it
    /// defensively and return an error result rather than guess.
    let argumentsJSON: String
}

struct ToolResult {
    let callId: String
    let content: String
    let isError: Bool
}

/// One finished model turn: what it said, the tools it wants, why it stopped, and the assistant
/// message in the provider's own format, to append to history unchanged.
struct ModelTurn {
    let text: String
    let toolCalls: [ToolCall]
    let stopReason: String
    let assistantMessage: [String: Any]
}

struct ProviderError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { status > 0 ? "\(message) (HTTP \(status))" : message }
}

enum ModelAPI {
    static func userMessage(_ text: String) -> [String: Any] {
        ["role": "user", "content": text]
    }

    /// Tool results as provider messages. Claude takes every result in one user message; the
    /// OpenAI format takes one `tool` message per result.
    static func toolResultMessages(_ results: [ToolResult], kind: ProviderKind) -> [[String: Any]] {
        switch kind {
        case .anthropic:
            let blocks: [[String: Any]] = results.map {
                var block: [String: Any] = ["type": "tool_result", "tool_use_id": $0.callId, "content": $0.content]
                if $0.isError { block["is_error"] = true }
                return block
            }
            return [["role": "user", "content": blocks]]
        case .openAICompatible:
            return results.map { ["role": "tool", "tool_call_id": $0.callId, "content": $0.content] }
        }
    }

    /// One streaming turn. `onText` receives text deltas as they arrive.
    static func streamTurn(config: ProviderConfig, system: String, messages: [[String: Any]],
                           tools: [ToolSpec], onText: @MainActor @escaping (String) -> Void) async throws -> ModelTurn {
        let request = try buildRequest(config: config, system: system, messages: messages, tools: tools)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError(status: 0, message: "No response from the provider") }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines where body.count < 4000 { body += line }
            throw ProviderError(status: http.statusCode, message: errorMessage(from: body))
        }
        var parser: StreamParser = config.kind == .anthropic ? AnthropicStreamParser() : OpenAIStreamParser()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let delta = try parser.consume(event) { await onText(delta) }
        }
        return parser.finish()
    }

    static func buildRequest(config: ProviderConfig, system: String, messages: [[String: Any]], tools: [ToolSpec]) throws -> URLRequest {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let path = config.kind == .anthropic ? "/v1/messages" : "/chat/completions"
        guard let url = URL(string: base + path) else {
            throw ProviderError(status: 0, message: "The provider's URL isn't valid: \(config.baseURL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any]
        switch config.kind {
        case .anthropic:
            request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": config.model,
                "max_tokens": 64000,
                "stream": true,
                "system": system,
                "messages": messages,
                "cache_control": ["type": "ephemeral"],
                "tools": tools.map {
                    ["name": $0.name, "description": $0.description, "input_schema": $0.schema,
                     "eager_input_streaming": true] as [String: Any]
                },
            ]
            if supportsEffort(config.model) { body["output_config"] = ["effort": "medium"] }
            // If a safety classifier declines, retry on the API's default fallback model.
            if supportsDefaultFallback(config.model) {
                request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                body["fallbacks"] = "default"
            }
        case .openAICompatible:
            if !config.apiKey.isEmpty { request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
            body = [
                "model": config.model,
                "stream": true,
                "messages": [["role": "system", "content": system]] + messages,
                "tools": tools.map {
                    ["type": "function",
                     "function": ["name": $0.name, "description": $0.description, "parameters": $0.schema]] as [String: Any]
                },
            ]
        }
        // Sorted keys: identical history serialises identically, which keeps Claude's cache valid.
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    private static func supportsEffort(_ model: String) -> Bool {
        !(model.contains("haiku-4") || model.contains("sonnet-4-5") || model.contains("-3-"))
    }

    private static func supportsDefaultFallback(_ model: String) -> Bool {
        ["claude-opus-5-5", "claude-opus-5", "claude-fable-5-1", "claude-sonnet-5-5"].contains(model)
    }

    private static func errorMessage(from body: String) -> String {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let message = json["error"] as? String { return message }
            if let message = json["message"] as? String { return message }
        }
        return body.isEmpty ? "The provider returned an error" : String(body.prefix(300))
    }
}

// MARK: - Agent loop

/// The conversation in the provider's own message format. Append-only: past turns are never
/// edited, because Claude's thinking blocks are only valid in the exact history that made them.
final class AssistantHistory {
    var messages: [[String: Any]] = []
}

enum AssistantLoop {
    static let maxSteps = 16

    /// Model turn → run its tools → feed back the results, until it finishes. Every tool call
    /// always gets a result, even when stopping early: providers reject a history with an
    /// unanswered call.
    @MainActor
    static func run(config: ProviderConfig, system: String, history: AssistantHistory, tools: [ToolSpec],
                    onTurnStart: @MainActor () -> Void,
                    onText: @MainActor @escaping (String) -> Void,
                    onNotice: @MainActor (String) -> Void,
                    execute: @MainActor (ToolCall) async -> ToolResult) async throws {
        for _ in 0..<maxSteps {
            onTurnStart()
            let turn = try await ModelAPI.streamTurn(config: config, system: system, messages: history.messages,
                                                     tools: tools, onText: onText)
            history.messages.append(turn.assistantMessage)

            let truncated = turn.stopReason == "max_tokens" || turn.stopReason == "length"
            if turn.stopReason == "refusal" { onNotice("The model declined that request.") }
            if truncated { onNotice("The reply hit the length limit and was cut off.") }
            if turn.stopReason == "pause_turn" { continue }
            if turn.toolCalls.isEmpty { return }

            var results: [ToolResult] = []
            for call in turn.toolCalls {
                if truncated || turn.stopReason == "refusal" || Task.isCancelled {
                    results.append(ToolResult(callId: call.id, content: "Not run: the turn ended early.", isError: true))
                } else {
                    results.append(await execute(call))
                }
            }
            history.messages += ModelAPI.toolResultMessages(results, kind: config.kind)
            if truncated || turn.stopReason == "refusal" { return }
            try Task.checkCancellation()
        }
        onNotice("Stopped after \(maxSteps) steps. Ask it to continue if there's more to do.")
    }
}

// MARK: - Stream parsers

private protocol StreamParser {
    /// Handle one SSE event; returns any text delta.
    mutating func consume(_ event: [String: Any]) throws -> String?
    func finish() -> ModelTurn
}

/// Claude. Content blocks are kept whole and in order, because thinking blocks (and their
/// signatures) must go back to the API unchanged on the next request.
private struct AnthropicStreamParser: StreamParser {
    private var blocks: [Int: [String: Any]] = [:]
    private var partialInput: [Int: String] = [:]
    private var stopReason = "end_turn"

    private mutating func append(_ text: String, to field: String, at index: Int) {
        guard var block = blocks[index] else { return }
        block[field] = (block[field] as? String ?? "") + text
        blocks[index] = block
    }

    mutating func consume(_ event: [String: Any]) throws -> String? {
        switch event["type"] as? String {
        case "content_block_start":
            guard let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any] else { return nil }
            blocks[index] = block
        case "content_block_delta":
            guard let index = event["index"] as? Int, let delta = event["delta"] as? [String: Any] else { return nil }
            switch delta["type"] as? String {
            case "text_delta":
                let text = delta["text"] as? String ?? ""
                append(text, to: "text", at: index)
                return text
            case "thinking_delta":
                append(delta["thinking"] as? String ?? "", to: "thinking", at: index)
            case "signature_delta":
                append(delta["signature"] as? String ?? "", to: "signature", at: index)
            case "input_json_delta":
                partialInput[index, default: ""] += delta["partial_json"] as? String ?? ""
            default:
                break
            }
        case "message_delta":
            if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String { stopReason = reason }
        case "error":
            let error = event["error"] as? [String: Any]
            throw ProviderError(status: 0, message: error?["message"] as? String ?? "The stream failed")
        default:
            break
        }
        return nil
    }

    func finish() -> ModelTurn {
        var content: [[String: Any]] = []
        var text = ""
        var calls: [ToolCall] = []
        for index in blocks.keys.sorted() {
            var block = blocks[index]!
            switch block["type"] as? String {
            case "text":
                text += block["text"] as? String ?? ""
            case "tool_use":
                let raw = partialInput[index] ?? "{}"
                // The echoed block needs a real object even if the streamed input was cut off;
                // the executor sees the raw text and reports it as invalid.
                let input = raw.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                block["input"] = input ?? [String: Any]()
                calls.append(ToolCall(id: block["id"] as? String ?? "", name: block["name"] as? String ?? "", argumentsJSON: raw))
            default:
                break
            }
            content.append(block)
        }
        return ModelTurn(text: text, toolCalls: calls, stopReason: stopReason,
                         assistantMessage: ["role": "assistant", "content": content])
    }
}

/// Kimi and other OpenAI-format providers.
private struct OpenAIStreamParser: StreamParser {
    private var text = ""
    private var reasoning = ""
    private var calls: [Int: (id: String, name: String, arguments: String)] = [:]
    private var stopReason = "stop"

    mutating func consume(_ event: [String: Any]) throws -> String? {
        if let error = event["error"] as? [String: Any] {
            throw ProviderError(status: 0, message: error["message"] as? String ?? "The stream failed")
        }
        guard let choice = (event["choices"] as? [[String: Any]])?.first else { return nil }
        if let reason = choice["finish_reason"] as? String { stopReason = reason }
        guard let delta = choice["delta"] as? [String: Any] else { return nil }
        reasoning += delta["reasoning_content"] as? String ?? ""
        for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
            let index = call["index"] as? Int ?? 0
            var entry = calls[index] ?? (id: "", name: "", arguments: "")
            if let id = call["id"] as? String, !id.isEmpty { entry.id = id }
            if let function = call["function"] as? [String: Any] {
                entry.name += function["name"] as? String ?? ""
                entry.arguments += function["arguments"] as? String ?? ""
            }
            calls[index] = entry
        }
        if let content = delta["content"] as? String, !content.isEmpty {
            text += content
            return content
        }
        return nil
    }

    func finish() -> ModelTurn {
        let ordered = calls.keys.sorted().map { calls[$0]! }
        var message: [String: Any] = ["role": "assistant", "content": text]
        if !ordered.isEmpty {
            message["tool_calls"] = ordered.map {
                ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] as [String: Any]
            }
        }
        if !reasoning.isEmpty { message["reasoning_content"] = reasoning }
        return ModelTurn(text: text, toolCalls: ordered.map { ToolCall(id: $0.id, name: $0.name, argumentsJSON: $0.arguments) },
                         stopReason: stopReason, assistantMessage: message)
    }
}

// MARK: - File tools

/// Files, limited to the folders chosen in Settings. Every path is resolved (symlinks and `..`
/// included) before it's checked, so nothing can step outside them.
struct FileTools {
    let roots: [String]

    private static let skippedFolders: Set<String> = [".git", "node_modules", ".venv", "__pycache__", "DerivedData", ".build"]
    private static let readLimit = 30_000
    private static let searchByteLimit = 6_000_000

    struct FileError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func canonical(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        // A path that doesn't exist yet can't have its symlinks resolved, so resolve the deepest
        // part that does exist, then add the rest back.
        var existing = URL(fileURLWithPath: expanded).standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        return missing.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
    }

    func resolve(_ path: String) throws -> String {
        guard !roots.isEmpty else { throw FileError(message: "No folders are allowed yet. Add one in Settings → Assistant.") }
        let first = NSString(string: roots[0]).expandingTildeInPath
        let absolute = path.hasPrefix("/") || path.hasPrefix("~") ? path : (first as NSString).appendingPathComponent(path)
        let resolved = canonical(absolute)
        let allowed = roots.map(canonical).contains { resolved == $0 || resolved.hasPrefix($0 + "/") }
        guard allowed else {
            throw FileError(message: "\(path) is outside the allowed folders: \(roots.joined(separator: ", "))")
        }
        return resolved
    }

    func list(_ path: String) throws -> String {
        let dir = try resolve(path)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir).filter { !$0.hasPrefix(".") }.sorted()
        var lines: [String] = []
        for name in names.prefix(300) {
            let full = (dir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
            let size = (try? FileManager.default.attributesOfItem(atPath: full)[.size] as? Int) ?? 0
            lines.append(isDir.boolValue ? "\(name)/" : "\(name)  (\(size) bytes)")
        }
        if names.count > 300 { lines.append("… and \(names.count - 300) more") }
        return lines.isEmpty ? "(empty folder)" : "\(dir)\n" + lines.joined(separator: "\n")
    }

    /// File names and text contents, case-insensitive, with a short excerpt around each match.
    func search(_ query: String, in path: String?) throws -> String {
        let folders = try path.map { [try resolve($0)] } ?? roots.map(canonical)
        let deadline = Date().addingTimeInterval(10)
        var results: [String] = []
        for folder in folders {
            guard let walker = FileManager.default.enumerator(atPath: folder) else { continue }
            while let relative = walker.nextObject() as? String {
                if results.count >= 40 || Date() > deadline { break }
                let name = (relative as NSString).lastPathComponent
                if name.hasPrefix(".") || Self.skippedFolders.contains(name) { walker.skipDescendants(); continue }
                let full = (folder as NSString).appendingPathComponent(relative)
                if name.range(of: query, options: .caseInsensitive) != nil { results.append("\(full)  (name matches)") }
                guard let text = Self.text(at: full, maxBytes: Self.searchByteLimit) else { continue }
                var from = text.startIndex
                var hits = 0
                while hits < 4, let match = text.range(of: query, options: .caseInsensitive, range: from..<text.endIndex) {
                    let start = text.index(match.lowerBound, offsetBy: -120, limitedBy: text.startIndex) ?? text.startIndex
                    let end = text.index(match.upperBound, offsetBy: 120, limitedBy: text.endIndex) ?? text.endIndex
                    let offset = text.distance(from: text.startIndex, to: match.lowerBound)
                    let excerpt = text[start..<end].replacingOccurrences(of: "\n", with: " ")
                    results.append("\(full) @\(offset): …\(excerpt)…")
                    from = match.upperBound
                    hits += 1
                }
            }
        }
        return results.isEmpty ? "No matches for “\(query)”." : results.joined(separator: "\n")
    }

    /// Up to 30,000 characters from `offset` (matches from search report their offset).
    func read(_ path: String, offset: Int) throws -> String {
        let file = try resolve(path)
        guard let text = Self.text(at: file, maxBytes: .max) else {
            throw FileError(message: "\(path) can't be read as text.")
        }
        guard offset < max(text.count, 1) else { return "(past the end: the file has \(text.count) characters)" }
        let start = text.index(text.startIndex, offsetBy: max(0, offset))
        let end = text.index(start, offsetBy: Self.readLimit, limitedBy: text.endIndex) ?? text.endIndex
        let shown = text.distance(from: text.startIndex, to: end)
        let tail = shown < text.count ? "\n\n[Showing up to character \(shown) of \(text.count). Read again with offset \(shown) for more.]" : ""
        return String(text[start..<end]) + tail
    }

    /// What a write would do, for the approval prompt.
    func writePreview(_ path: String, content: String) throws -> String {
        let file = try resolve(path)
        guard let old = Self.text(at: file, maxBytes: .max) else {
            return "Create \(file)\n\n" + content.split(separator: "\n", omittingEmptySubsequences: false).prefix(14).joined(separator: "\n")
        }
        let before = old.components(separatedBy: "\n"), after = content.components(separatedBy: "\n")
        var head = 0
        while head < min(before.count, after.count), before[head] == after[head] { head += 1 }
        var tail = 0
        while tail < min(before.count, after.count) - head, before[before.count - 1 - tail] == after[after.count - 1 - tail] { tail += 1 }
        let removed = before[head..<(before.count - tail)], added = after[head..<(after.count - tail)]
        var lines = ["Change \(file)", "\(removed.count) line(s) removed, \(added.count) added, from line \(head + 1)", ""]
        lines += removed.prefix(8).map { "- \($0)" }
        lines += added.prefix(8).map { "+ \($0)" }
        return lines.joined(separator: "\n")
    }

    func write(_ path: String, content: String) throws -> String {
        let file = try resolve(path)
        try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try content.write(toFile: file, atomically: true, encoding: .utf8)
        return "Wrote \(file) (\(content.count) characters)."
    }

    /// The file as text, or nil if it's missing, too large, or binary.
    private static func text(at path: String, maxBytes: Int) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
              let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int, size <= maxBytes,
              let data = FileManager.default.contents(atPath: path), !data.prefix(4096).contains(0) else { return nil }
        return String(data: data, encoding: .utf8)   // strict: anything else isn't text
    }
}
