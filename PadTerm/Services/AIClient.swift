import Foundation

// MARK: - AI 模型（对话消息）

struct AIMessage: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var role: Role
    var content: String
    var timestamp: Date = Date()

    enum Role: String, Codable {
        case system, user, assistant
    }

    static func user(_ text: String) -> AIMessage { AIMessage(role: .user, content: text) }
    static func assistant(_ text: String) -> AIMessage { AIMessage(role: .assistant, content: text) }
    static func system(_ text: String) -> AIMessage { AIMessage(role: .system, content: text) }
}

/// 会话模式：普通问答 / 设备问答（带设备上下文与诊断能力）
enum AISessionMode: String, CaseIterable, Identifiable, Codable {
    case general = "普通问答"
    case device = "设备问答"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: return "bubble.left.and.bubble.right"
        case .device: return "cpu"
        }
    }
}

struct AISettings: Codable {
    /// 默认留空：地址、模型、Key 全部由使用者在设置页自行填写，避免任何私人凭证被写进源码
    var baseURL: String = ""
    var apiKey: String = ""
    var model: String = ""
    var temperature: Double = 0.3
    var systemPrompt: String = "你是一名资深的 Linux 与嵌入式系统运维专家，回答要简洁、准确、给出可直接执行的命令。"

    /// 预设服务商：只存地址与默认模型，Key 由使用者自己填（避免把密钥写进源码）
    struct Preset: Identifiable {
        let id = UUID()
        var name: String
        var baseURL: String
        var model: String
        var apiKey: String = ""
        var note: String = ""
    }

    enum Presets {
        static let all: [Preset] = [
            Preset(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini"),
            Preset(name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat"),
            Preset(name: "Moonshot（Kimi）", baseURL: "https://api.moonshot.cn/v1", model: "moonshot-v1-8k"),
            Preset(name: "通义千问", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-plus"),
            Preset(name: "智谱 GLM", baseURL: "https://open.bigmodel.cn/api/paas/v4", model: "glm-4-flash"),
            Preset(name: "硅基流动", baseURL: "https://api.siliconflow.cn/v1", model: "Qwen/Qwen2.5-7B-Instruct"),
            Preset(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", model: "openai/gpt-4o-mini"),
            Preset(name: "Ollama（本机）", baseURL: "http://localhost:11434/v1", model: "qwen2.5:7b",
                   note: "需 iPad 能访问该地址，且 Ollama 已开启局域网监听"),
            Preset(name: "LM Studio（本机）", baseURL: "http://localhost:1234/v1", model: "local-model",
                   note: "需开启 Server 与局域网访问")
        ]
    }

    private static let key = "padterm.ai.settings"

    static func load() -> AISettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(AISettings.self, from: data) else { return AISettings() }
        return value
    }

    func persist() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

// MARK: - OpenAI 兼容流客户端

enum AIError: LocalizedError {
    case missingKey
    case badURL
    case http(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingKey: return "未配置 API Key，请到「设置」里填写"
        case .badURL: return "API 地址不合法"
        case .http(let code, let body): return "接口返回 \(code)：\(body)\n\(Self.diagnosis(code: code))"
        case .emptyResponse: return "接口没有返回内容"
        }
    }

    /// 常见状态码的排查指引，避免只看到一串裸 JSON 不知所措
    static func diagnosis(code: Int) -> String {
        switch code {
        case 404:
            return "排查：404 说明这个域名/路径上没有该接口。常见原因：① 版本路径写错（例如应是 /v1 写成了 /v2）；② 填的域名本身不提供 OpenAI 兼容接口；③ 自己把 /chat/completions 拼了进去（App 会自动补）。"
        case 401, 403:
            return "排查：API Key 无效、过期，或该 Key 没有此模型的权限。"
        case 429:
            return "排查：触发限流或额度不足，稍后重试或充值。"
        case 400:
            return "排查：请求参数被拒，通常是模型名写错。"
        case 500...599:
            return "排查：服务端异常，稍后重试。"
        default:
            return ""
        }
    }
}

final class AIClient {
    private let settings: AISettings

    init(settings: AISettings) { self.settings = settings }

    /// 实际请求地址（设置页展示，方便一眼看出拼错没拼错）
    static func endpoint(for settings: AISettings) -> String {
        var base = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base.removeLast() }
        if !base.hasPrefix("http") { base = "https://" + base }
        return base.hasSuffix("/chat/completions") ? base : base + "/chat/completions"
    }

    /// 404 时自动在同一域名下探测其它常见前缀，返回「候选地址 -> 状态码」
    static func probe(baseURL: String, apiKey: String) async -> [(String, Int)] {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base.removeLast() }
        guard let comps = URLComponents(string: base.hasPrefix("http") ? base : "https://" + base),
              let scheme = comps.scheme, let host = comps.host else { return [] }
        var candidates: [String] = []
        let prefixes = ["", "/v1", "/v1/openai", "/api/v1", "/openapi/v1", "/openai/v1", "/compatible-mode/v1"]
        for prefix in prefixes {
            candidates.append("\(scheme)://\(host)\(prefix)/models")
        }
        var results: [(String, Int)] = []
        for urlString in candidates {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 8
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                results.append((urlString, code))
            } catch {
                results.append((urlString, 0))
            }
        }
        return results
    }

    /// 流式返回增量文本
    func stream(messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        let settings = self.settings
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.performStream(settings: settings, messages: messages) { delta in
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private static func performStream(settings: AISettings,
                                      messages: [AIMessage],
                                      onDelta: @escaping (String) -> Void) async throws {
        guard !settings.apiKey.isEmpty else { throw AIError.missingKey }
        var base = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base.removeLast() }
        if !base.hasPrefix("http") { base = "https://" + base }
        // 已经写到 /chat/completions 的就别再拼一次，避免变成 .../chat/completions/chat/completions
        let endpoint = base.hasSuffix("/chat/completions") ? base : base + "/chat/completions"
        guard let url = URL(string: endpoint) else { throw AIError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let payload: [String: Any] = [
            "model": settings.model,
            "stream": true,
            "temperature": settings.temperature,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // AsyncBytes 的元素是 UInt8，需要自行拼接
            var body = ""
            for try await byte in bytes {
                body.append(Character(UnicodeScalar(byte)))
                if body.count > 500 { break }
            }
            throw AIError.http(http.statusCode, body)
        }

        var gotSomething = false
        if try await Self.consumeSSE(bytes, onDelta: { gotSomething = true; onDelta($0) }) == .done { return }
        if !gotSomething { throw AIError.emptyResponse }

    }

    private enum SSEStatus { case `continue`, done }

    /// 按 SSE 行（以 \n 分隔）解析 data: 增量；返回 .done 表示收到 [DONE]
    private static func consumeSSE(_ bytes: URLSession.AsyncBytes,
                                   onDelta: (String) -> Void) async throws -> SSEStatus {
        var buffer: [UInt8] = []

        func handle(_ lineBytes: [UInt8]) -> SSEStatus? {
            guard let line = String(bytes: lineBytes, encoding: .utf8) else { return nil }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { return nil }
            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { return .done }
            guard let value = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: value) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let text = delta["content"] as? String, !text.isEmpty
            else { return nil }
            onDelta(text)
            return nil
        }

        for try await byte in bytes {
            if byte == 0x0A {                       // \n
                if let status = handle(buffer) { return status }
                buffer.removeAll(keepingCapacity: true)
            } else if byte != 0x0D {                // 忽略 \r
                buffer.append(byte)
                if buffer.count > 1_000_000 { buffer.removeAll(keepingCapacity: true) }
            }
        }
        if let status = handle(buffer) { return status }
        return .continue
    }
}

// MARK: - 设备问答的系统提示拼装

enum DevicePrompt {
    static func buildSystem(settings: AISettings, host: HostConfig?, snapshot: MetricSnapshot?) -> AIMessage {
        var text = settings.systemPrompt
        if let host {
            text += "\n\n【当前设备上下文】\n主机名称：\(host.name)\nSSH：\(host.subtitle)\n类型：\(host.kind.rawValue)"
            if !host.note.isEmpty { text += "\n备注：\(host.note)" }
        }
        if let snapshot, let host {
            text += "\n\n【实时指标快照】\n" + snapshot.summaryForAI(host: host.name)
        }
        if host != nil {
            text += """

            \n【重要：你有命令执行能力】
            1. 需要查看真实数据时，用 ```bash 代码块给出命令（如 ps/top/df/free/journalctl/dmesg/lsblk/iostat/ss/netstat/du），
               系统会自动在该设备上执行，并把 stdout、stderr、退出码原样返回给你。
            2. 一次只给 1~3 条命令，看到输出后再决定是否需要补充；禁止凭空猜测输出。
            3. 收到命令输出后必须基于真实输出作答，给出「结论 + 依据（引用关键输出） + 建议动作」。
            4. 优先只读命令。会破坏数据或改变系统状态的命令（rm/mkfs/dd/reboot/kill/systemctl stop 等）
               会被系统拦截，不要尝试；确需修改时，明确说明风险并让用户自己执行。
            5. 回答用中文，条理清晰。
            """
        }
        return .system(text)
    }
}
