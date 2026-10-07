import Foundation
import Network

/// TCP 连通性预检：SSH 连接失败时用它区分「被系统权限拦截 / 端口未开放 / 主机不可达」
enum NetworkProbe {
    enum Verdict {
        case ok
        case failed(String)
    }

    static func tcpCheck(host: String, port: Int, timeout: TimeInterval = 5) async -> Verdict {
        guard port > 0, port <= 65535, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return .failed("端口非法：\(port)")
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let connection = NWConnection(to: endpoint, using: NWParameters.tcp)

        return await withCheckedContinuation { (continuation: CheckedContinuation<Verdict, Never>) in
            let lock = NSLock()
            var finished = false
            let finish: (Verdict) -> Void = { verdict in
                lock.lock()
                guard !finished else { lock.unlock(); return }
                finished = true
                lock.unlock()
                connection.cancel()
                continuation.resume(returning: verdict)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.ok)
                case .failed(let error):
                    finish(.failed(describe(error)))
                case .waiting(let error):
                    // 等待通常是本机没有可用路由或尚未授权访问本地网络
                    finish(.failed("连接处于等待/阻塞状态：\(describe(error))"))
                case .cancelled:
                    finish(.failed("连接被取消"))
                default:
                    break
                }
            }

            let queue = DispatchQueue(label: "com.padterm.tcpprobe")
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(.failed("\(Int(timeout)) 秒内未建立连接（主机不可达或端口被防火墙丢弃）"))
            }
        }
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            return "\(code) (\(error.localizedDescription))"
        case .dns(let code):
            return "DNS 错误 \(code)：\(error.localizedDescription)"
        case .tls(let code):
            return "TLS 错误 \(code)：\(error.localizedDescription)"
        default:
            return error.localizedDescription
        }
    }
}
