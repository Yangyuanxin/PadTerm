import Foundation

/// 单块磁盘/分区使用情况
struct DiskUsage: Identifiable, Hashable {
    var id: String { "\(filesystem)|\(mountPoint)" }
    var filesystem: String
    var fstype: String
    var totalMB: Double
    var usedMB: Double
    var availMB: Double
    var mountPoint: String

    var usedPercent: Double {
        guard totalMB > 0 else { return 0 }
        return usedMB / totalMB * 100
    }
}

/// CPU 单核占用（用于柱状图/Grid）
struct CoreUsage: Identifiable, Hashable {
    var id: Int { index }
    var index: Int
    var percent: Double
}

struct ProcessStat: Identifiable, Hashable {
    var id: Int { pid }
    var pid: Int
    var command: String
    var cpuPercent: Double
    var memPercent: Double
}

struct NetInterfaceStat: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var rxKBps: Double
    var txKBps: Double
}

/// 一次完整采样结果
struct MetricSnapshot: Identifiable, Hashable {
    var id: Date { timestamp }
    var timestamp: Date

    var cpuTotalPercent: Double
    var cores: [CoreUsage]
    var loadAvg1: Double
    var loadAvg5: Double
    var loadAvg15: Double

    var memTotalMB: Double
    var memUsedMB: Double
    var memCachedMB: Double
    var swapTotalMB: Double
    var swapUsedMB: Double

    var disks: [DiskUsage]
    var diskReadKBps: Double
    var diskWriteKBps: Double

    var interfaces: [NetInterfaceStat]
    var netRxKBps: Double
    var netTxKBps: Double

    var uptimeSeconds: Double
    var cpuTempC: Double?

    var topProcesses: [ProcessStat]
    /// 采集过程中的告警/失败项，便于排障
    var warnings: [String]

    static var empty: MetricSnapshot {
        MetricSnapshot(timestamp: Date(), cpuTotalPercent: 0, cores: [], loadAvg1: 0, loadAvg5: 0,
                       loadAvg15: 0, memTotalMB: 0, memUsedMB: 0, memCachedMB: 0, swapTotalMB: 0,
                       swapUsedMB: 0, disks: [], diskReadKBps: 0, diskWriteKBps: 0, interfaces: [],
                       netRxKBps: 0, netTxKBps: 0, uptimeSeconds: 0, cpuTempC: nil,
                       topProcesses: [], warnings: [])
    }

    var memUsedPercent: Double {
        guard memTotalMB > 0 else { return 0 }
        return memUsedMB / memTotalMB * 100
    }

    var uptimeText: String {
        let s = Int(uptimeSeconds)
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)天\(h)小时" }
        if h > 0 { return "\(h)小时\(m)分" }
        return "\(m)分\(s % 60)秒"
    }

    /// 给 AI 会话使用的简明文本摘要
    func summaryForAI(host: String) -> String {
        var lines: [String] = []
        lines.append("设备: \(host)")
        lines.append("时间: \(ISO8601DateFormatter().string(from: timestamp))")
        lines.append(String(format: "CPU: %.1f%% (核心数 %d, 负载 %.2f %.2f %.2f)",
                            cpuTotalPercent, cores.count, loadAvg1, loadAvg5, loadAvg15))
        lines.append(String(format: "内存: %.0f/%.0f MB (%.1f%%), swap %.0f/%.0f MB, cache %.0f MB",
                            memUsedMB, memTotalMB, memUsedPercent, swapUsedMB, swapTotalMB, memCachedMB))
        lines.append(String(format: "磁盘IO: 读 %.1f KB/s, 写 %.1f KB/s", diskReadKBps, diskWriteKBps))
        lines.append(String(format: "网络: 下行 %.1f KB/s, 上行 %.1f KB/s", netRxKBps, netTxKBps))
        lines.append("运行时长: \(uptimeText)")
        if let t = cpuTempC { lines.append(String(format: "CPU温度: %.1f °C", t)) }
        if !disks.isEmpty {
            lines.append("磁盘分区:")
            for d in disks {
                lines.append(String(format: "  %@ (%@) %.0f/%.0f MB 已用%.1f%% mount=%@",
                                    d.filesystem, d.fstype, d.usedMB, d.totalMB, d.usedPercent, d.mountPoint))
            }
        }
        if !topProcesses.isEmpty {
            lines.append("占用最高的进程:")
            for p in topProcesses.prefix(8) {
                lines.append(String(format: "  pid=%d cpu=%.1f%% mem=%.1f%% %@", p.pid, p.cpuPercent, p.memPercent, p.command))
            }
        }
        if !warnings.isEmpty {
            lines.append("采集异常: " + warnings.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }
}
