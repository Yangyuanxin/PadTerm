import Foundation
import SwiftUI

/// 监控页视图模型：周期性 SSH 采集设备指标
@MainActor
final class MetricsViewModel: ObservableObject {
    let host: HostConfig
    private let service: SSHService

    @Published var history: [MetricSnapshot] = []
    @Published var current: MetricSnapshot?
    @Published var isBusy = false
    @Published var isRunning = false
    @Published var errorMessage: String?
    @Published var interval: Double

    private var pollTask: Task<Void, Never>?
    private var collector: MetricsCollector?
    private let maxHistory = 180

    init(host: HostConfig, service: SSHService) {
        self.host = host
        self.service = service
        self.interval = host.pollInterval
    }

    func start() {
        guard pollTask == nil else { return }
        collector = MetricsCollector { [service] command, timeout in
            let result = try await service.exec(command, timeout: timeout)
            return result.stdout
        }
        isRunning = true
        errorMessage = nil
        let waitNanos = UInt64(max(0.5, interval) * 1_000_000_000)
        pollTask = Task { [weak self] in
            await self?.collect()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: waitNanos)
                if Task.isCancelled { break }
                await self?.collect()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        isRunning = false
        collector = nil
    }

    func refreshOnce() {
        Task { [weak self] in
            await self?.collect()
        }
    }

    private func collect() async {
        guard let collector, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            // 先探一次连通性，给出清晰失败原因
            _ = try await service.exec("echo ok", timeout: 8)
            let snapshot = await collector.snapshot()
            current = snapshot
            errorMessage = nil
            var next = history
            next.append(snapshot)
            if next.count > maxHistory { next.removeFirst(next.count - maxHistory) }
            history = next
        } catch {
            errorMessage = "采集失败：\(error.localizedDescription)"
        }
    }
}
