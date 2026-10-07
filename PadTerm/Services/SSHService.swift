import Foundation
import NIOCore
import NIOPosix
import NIOSSH

enum SSHError: LocalizedError {
    case notConnected
    case timeout
    case authFailed(String)
    case transport(host: String, port: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "SSH 尚未连接"
        case .timeout: return "命令执行超时"
        case .authFailed(let text): return "认证失败：\(text)"
        case .transport(let host, let port, let detail):
            return """
            无法建立到 \(host):\(port) 的 TCP 连接（\(detail)）
            请依次确认：
            1. 系统「本地网络」权限是否允许 PadTerm（系统设置 → 隐私与安全性 → 本地网络）
            2. 本机与设备在同一局域网，且 22 端口可达
            3. 设备已开机且 sshd 正在运行
            """
        }
    }
}

struct ExecResult {
    var stdout: String
    var stderr: String
    var exitCode: Int?
}

// MARK: - 主机密钥校验：信任首次连接（TOFU）

final class TrustFirstUseKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // 家用内网设备（打印机/树莓派）通常无固定 CA，按 SSH 客户端惯例接受本机首次见到的密钥
        validationCompletePromise.succeed(())
    }
}

// MARK: - 用户认证委托：按「无密码(none) → 密码」依次尝试

/// 家里的打印机/开发板常见两种情况：
/// 1. 服务器开了 `none` 认证（机器猫/none auth），此时不能用空密码的 password 认证去试，会被拒；
/// 2. 需要真实密码。
/// 因此这里把候选认证方式排队，一次失败就让 NIOSSH 继续走下一个。
final class PadTermAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private var pending: [NIOSSHUserAuthenticationOffer]

    init(username: String, password: String) {
        let offers: [NIOSSHUserAuthenticationOffer.Offer]
        if password.isEmpty {
            // 未提供密码：先试 none（例如 root 无密码的 3D 打印机主板），再退回空密码 password
            offers = [.none, .password(.init(password: ""))]
        } else {
            offers = [.password(.init(password: password)), .none]
        }
        pending = offers.map {
            NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: $0)
        }
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !pending.isEmpty else {
            nextChallengePromise.succeed(nil)
            return
        }
        nextChallengePromise.succeed(pending.removeFirst())
    }
}

// MARK: - SSH 连接服务

final class SSHService {
    let host: HostConfig
    private let group: MultiThreadedEventLoopGroup
    private(set) var channel: Channel?
    private var connecting = false

    init(host: HostConfig) {
        self.host = host
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    var isConnected: Bool { channel?.isActive ?? false }

    func connect() async throws {
        if let ch = channel, ch.isActive { return }
        // 有在途的连接尝试：等它出结果，而不是静默返回
        // （旧逻辑空转 10 秒后直接 return，导致上层拿到未连接通道报「SSH 尚未连接」）
        while connecting {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if let ch = channel, ch.isActive { return }
        }
        if let ch = channel, ch.isActive { return }
        connecting = true
        defer { connecting = false }

        let password = KeychainHelper.password(for: host.id.uuidString) ?? ""
        let config = SSHClientConfiguration(
            userAuthDelegate: PadTermAuthDelegate(username: host.username, password: password),
            serverAuthDelegate: TrustFirstUseKeyDelegate()
        )

        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(TimeAmount.seconds(12))
            .channelInitializer { channel in
                channel.pipeline.addHandler(
                    NIOSSHHandler(role: .client(config),
                                  allocator: channel.allocator,
                                  inboundChildChannelInitializer: nil)
                )
            }
        FileLog.log("SSH connect → \(host.username)@\(host.hostname):\(host.port)")
        do {
            self.channel = try await bootstrap.connect(host: host.hostname, port: host.port).get()
        } catch {
            // 再做一次纯 TCP 预检，帮用户区分：权限拦截 / 端口未开 / 主机不可达
            var detail = String(describing: error)
            if detail.count > 240 { detail = String(detail.prefix(240)) + "…" }
            if case .failed(let reason) = await NetworkProbe.tcpCheck(host: host.hostname, port: host.port) {
                detail = reason
            } else {
                detail = "\(detail)（TCP 可达，可能是端口/握手问题）"
            }
            FileLog.log("SSH connect FAIL \(host.username)@\(host.hostname):\(host.port) → \(detail)")
            throw SSHError.transport(host: host.hostname, port: host.port, detail: detail)
        }
    }

    func close() {
        guard let conn = channel else { return }
        channel = nil
        conn.eventLoop.execute { conn.close(promise: nil) }
    }

    // MARK: - 单次命令执行

    func exec(_ command: String, timeout: TimeInterval = 20) async throws -> ExecResult {
        try await connect()
        guard let conn = channel, conn.isActive else { throw SSHError.notConnected }

        let loop = conn.eventLoop
        let collector = ExecCollector(promise: loop.makePromise(of: ExecResult.self))

        // 所有 NIO 操作必须在通道自己的 EventLoop 上执行：
        // async/await 恢复后的线程未必是 EventLoop 线程，跨线程调用 pipeline 会触发
        // 「Precondition failed」或各类随机 ChannelError
        let child = try await childChannelFuture(on: conn)
            .flatMap { childChannel -> EventLoopFuture<Channel> in
                childChannel.pipeline.addHandler(collector)
                    .flatMap { childChannel.setOption(ChannelOptions.autoRead, value: true) }
                    .map { childChannel }
            }.get()

        loop.execute {
            child.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true),
                promise: nil
            )
        }

        do {
            let result = try await withThrowingTaskGroup(of: ExecResult.self) { taskGroup -> ExecResult in
                taskGroup.addTask { try await collector.promise.futureResult.get() }
                taskGroup.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw SSHError.timeout
                }
                let value = try await taskGroup.next()!
                taskGroup.cancelAll()
                return value
            }
            child.eventLoop.execute { child.close(promise: nil) }
            return result
        } catch {
            child.eventLoop.execute { child.close(promise: nil) }
            throw error
        }
    }

    // MARK: - 交互式 PTY shell

    func openShell(cols: Int, rows: Int) async throws -> ShellSession {
        try await connect()
        guard let conn = channel, conn.isActive else { throw SSHError.notConnected }
        let loop = conn.eventLoop
        let ioHandler = ShellIOHandler()

        // 子通道创建 / setOption 必须带超时：TCP 半死（板子假在线）时
        // 这些 future 可能永远不完成，界面会卡在「连接中」
        let child = try await Self.withTimeout(seconds: 10) { [self] in
            try await childChannelFuture(on: conn)
                .flatMap { childChannel -> EventLoopFuture<Channel> in
                    childChannel.pipeline.addHandler(ioHandler).map { childChannel }
                }.get()
        }
        let session = ShellSession(channel: child, ioHandler: ioHandler)

        loop.execute {
            child.triggerUserOutboundEvent(
                SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: cols,
                    terminalRowHeight: rows,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: SSHTerminalModes([:])
                ),
                promise: nil
            )
            child.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ShellRequest(wantReply: true),
                promise: nil
            )
        }
        try await Self.withTimeout(seconds: 10) {
            try await loop.flatSubmit { child.setOption(ChannelOptions.autoRead, value: true) }.get()
        }
        return session
    }

    /// 给无超时的 NIO future 包一层墙钟超时
    private static func withTimeout<T: Sendable>(seconds: TimeInterval,
                                                 _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SSHError.timeout
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

    // MARK: - 内部：创建会话子通道（在 EventLoop 上完成）

    private func childChannelFuture(on conn: Channel) -> EventLoopFuture<Channel> {
        let loop = conn.eventLoop
        return loop.flatSubmit {
            conn.pipeline.handler(type: NIOSSHHandler.self).flatMap { handler -> EventLoopFuture<Channel> in
                let promise = loop.makePromise(of: Channel.self)
                handler.createChannel(promise, channelType: .session) { childChannel, _ in
                    childChannel.eventLoop.makeSucceededVoidFuture()
                }
                return promise.futureResult
            }
        }
    }
}

// MARK: - exec 输出收集器

private final class ExecCollector: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    let promise: EventLoopPromise<ExecResult>
    private var stdout = ""
    private var stderr = ""
    private var exitCode: Int?

    init(promise: EventLoopPromise<ExecResult>) { self.promise = promise }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = self.unwrapInboundIn(data)
        if case .byteBuffer(var buffer) = payload.data {
            let text = buffer.readString(length: buffer.readableBytes) ?? ""
            if payload.type == .stdErr { stderr += text } else { stdout += text }
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            exitCode = status.exitStatus
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        promise.succeed(ExecResult(stdout: stdout, stderr: stderr, exitCode: exitCode))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.close(promise: nil)
    }
}

// MARK: - 交互式会话

final class ShellSession {
    fileprivate(set) var ioHandler: ShellIOHandler
    private let channel: Channel

    var onOutput: ((Data) -> Void)? {
        get { ioHandler.onData }
        set { ioHandler.onData = newValue }
    }

    var onClose: (() -> Void)? {
        get { ioHandler.onClose }
        set { ioHandler.onClose = newValue }
    }

    /// 会话内错误（例如 SSH 层异常）会原样回传给界面，便于定位
    var onError: ((String) -> Void)? {
        get { ioHandler.onError }
        set { ioHandler.onError = newValue }
    }

    init(channel: Channel, ioHandler: ShellIOHandler) {
        self.channel = channel
        self.ioHandler = ioHandler
    }

    /// 写/控制操作都要切到通道自己的 EventLoop
    private func onLoop(_ body: @escaping (Channel) -> Void) {
        let target = channel
        target.eventLoop.execute { body(target) }
    }

    func write(_ data: Data) {
        onLoop { channel in
            guard channel.isActive else { self.ioHandler.onError?("会话已关闭，未能发送") ; return }
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            channel.writeAndFlush(SSHChannelData(type: .channel, data: IOData.byteBuffer(buffer)), promise: nil)
        }
    }

    func write(text: String) { write(Data(text.utf8)) }

    func resize(cols: Int, rows: Int) {
        onLoop { channel in
            guard channel.isActive else { return }
            channel.triggerUserOutboundEvent(
                SSHChannelRequestEvent.WindowChangeRequest(
                    terminalCharacterWidth: cols,
                    terminalRowHeight: rows,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0
                ),
                promise: nil
            )
        }
    }

    func close() {
        let handler = ioHandler
        onLoop { channel in
            handler.userClosed = true      // 主动断开不要再弹「会话异常」
            channel.close(promise: nil)
        }
    }
}

final class ShellIOHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    var onData: ((Data) -> Void)?
    var onClose: (() -> Void)?
    var onError: ((String) -> Void)?
    /// 标记本机主动关闭，避免把 tcpShutdown 之类的正常收尾当成异常
    var userClosed = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = self.unwrapInboundIn(data)
        if case .byteBuffer(var buffer) = payload.data {
            let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
            let out = Data(bytes)
            if let handler = onData { handler(out) }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        let closing = userClosed
        DispatchQueue.main.async { if !closing { self.onClose?() } }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        let text = String(describing: error)
        let closing = userClosed
        DispatchQueue.main.async {
            if !closing {
                self.onError?(text)
                self.onClose?()
            }
        }
        context.close(promise: nil)
    }
}
