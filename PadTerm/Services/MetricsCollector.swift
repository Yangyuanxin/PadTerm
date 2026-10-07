import Foundation

/// 在远端 Linux 主机上采集 CPU / 内存 / 存储 / IO / 网络等指标。
/// 采集策略：尽量只用 /proc 文件系统（BusyBox、Debian、树莓派都能用），
/// 每个采集项独立容错，任何一条命令不被支持都不会让整次采样失败。
final class MetricsCollector {

    struct Executor {
        var run: (String, TimeInterval) async throws -> String
    }

    private let run: (String, TimeInterval) async throws -> String

    init(exec: @escaping (String, TimeInterval) async throws -> String) {
        self.run = exec
    }

    // MARK: - 对外：一次完整采样

    func snapshot() async -> MetricSnapshot {
        var warnings: [String] = []

        // 第一轮：计数器快照 —— 需要两次采样才能算出 CPU/IO/网络速率
        let first = await sampleBase()
        // 等一小段Ticks —— 放在本地 sleep，不占用远端子进程
        try? await Task.sleep(nanoseconds: 900_000_000)
        let second = await sampleBase()

        var snapshot = MetricSnapshot.empty
        snapshot.timestamp = Date()
        snapshot.warnings = warnings

        // ---- CPU ----
        if let cpuDelta = delta(firstLine: first.stat, secondLine: second.stat) {
            snapshot.cpuTotalPercent = cpuDelta.usage
            snapshot.cores = cpuDelta.cores.enumerated().map { CoreUsage(index: $0.offset + 1, percent: $0.element) }
        } else {
            warnings.append("CPU(/proc/stat)读取失败")
        }

        // ---- 内存 ----
        if let mem = parseMemInfo(second.meminfo) {
            snapshot.memTotalMB = mem.totalMB
            snapshot.memUsedMB = max(0, mem.totalMB - mem.availableMB)
            snapshot.memCachedMB = mem.cachedMB
            snapshot.swapTotalMB = mem.swapTotalMB
            snapshot.swapUsedMB = max(0, mem.swapTotalMB - mem.swapFreeMB)
        } else {
            warnings.append("内存(/proc/meminfo)读取失败")
        }

        // ---- 负载 & 运行时长 ----
        let loads = parseLoadAvg(second.loadavg)
        snapshot.loadAvg1 = loads.0
        snapshot.loadAvg5 = loads.1
        snapshot.loadAvg15 = loads.2
        if loads.0 == -1 { warnings.append("负载(/proc/loadavg)读取失败") }

        snapshot.uptimeSeconds = parseUptime(second.uptime)

        // ---- 磁盘容量 ----
        let disks = parseDF(second.df)
        snapshot.disks = disks
        if disks.isEmpty { warnings.append("磁盘(df)读取失败") }

        // ---- 磁盘 IO 速率（KB/s）----
        if let io = diskIODelta(first: first.diskstats, second: second.diskstats, elapsed: first.elapsed + second.elapsed + 0.9) {
            snapshot.diskReadKBps = io.read
            snapshot.diskWriteKBps = io.write
        }

        // ---- 网络速率（KB/s）----
        let net = netIO(first: first.netdev, second: second.netdev, elapsed: 0.9)
        snapshot.interfaces = net.interfaces
        snapshot.netRxKBps = net.totalRx
        snapshot.netTxKBps = net.totalTx

        // ---- 温度 ----
        snapshot.cpuTempC = parseThermal(second.thermal)

        // ---- 进程 TOP ----
        let procs = topProcesses(fromPS: second.ps,
                                 firstProc: first.procstat,
                                 secondProc: second.procstat,
                                 memTotalMB: snapshot.memTotalMB)
        if !procs.isEmpty {
            snapshot.topProcesses = procs
        } else {
            warnings.append("进程列表：ps 与 /proc 都不可用（BusyBox 设备常见）")
        }
        FileLog.log("METRICS ps=\(second.ps.count)B procstat=\(second.procstat.count)B df=\(second.df.count)B procs=\(procs.count)")

        snapshot.warnings = warnings
        return snapshot
    }

    // MARK: - 远端一次性取回所有原始文件

    private struct RawSample {
        var stat: String = ""
        var meminfo: String = ""
        var loadavg: String = ""
        var uptime: String = ""
        var diskstats: String = ""
        var netdev: String = ""
        var df: String = ""
        var ps: String = ""
        var procstat: String = ""
        var thermal: String = ""
        var elapsed: Double = 0
    }

    private func sampleBase() async -> RawSample {
        let script = #"""
        echo "==STAT=="; cat /proc/stat; \
        echo "==MEMINFO=="; cat /proc/meminfo; \
        echo "==LOADAVG=="; cat /proc/loadavg; \
        echo "==UPTIME=="; cat /proc/uptime; \
        echo "==DISKSTATS=="; cat /proc/diskstats; \
        echo "==NETDEV=="; cat /proc/net/dev; \
        echo "==DF=="; df -PT 2>/dev/null || df -P 2>/dev/null || df -k 2>/dev/null || df 2>/dev/null; \
        echo "==PS=="; (ps -eo pid,pcpu,pmem,comm --sort=-pcpu 2>/dev/null || ps aux 2>/dev/null || ps w 2>/dev/null) | head -n 12; \
        echo "==PROCSTAT=="; for p in /proc/[0-9]*; do cat "$p/stat" 2>/dev/null; echo; cat "$p/cmdline" 2>/dev/null | tr '\0' ' '; echo; done; \
        echo "==THERMAL=="; cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || vcgencmd measure_temp 2>/dev/null
        """#
        do {
            let output = try await run(script, 15)
            return splitSections(output)
        } catch {
            return RawSample()
        }
    }

    private func splitSections(_ text: String) -> RawSample {
        var raw = RawSample()
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("==") {
                current = line.trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            switch current {
            case "==STAT==": raw.stat += line + "\n"
            case "==MEMINFO==": raw.meminfo += line + "\n"
            case "==LOADAVG==": raw.loadavg += line + "\n"
            case "==UPTIME==": raw.uptime += line + "\n"
            case "==DISKSTATS==": raw.diskstats += line + "\n"
            case "==NETDEV==": raw.netdev += line + "\n"
            case "==DF==": raw.df += line + "\n"
            case "==PS==": raw.ps += line + "\n"
            case "==PROCSTAT==": raw.procstat += line + "\n"
            case "==THERMAL==": raw.thermal += line + "\n"
            default: break
            }
        }
        return raw
    }

    // MARK: - 解析函数

    private struct CPUDelta { var usage: Double; var cores: [Double] }

    private func delta(firstLine: String, secondLine: String) -> CPUDelta? {
        let a = parseCPUStat(firstLine)
        let b = parseCPUStat(secondLine)
        guard let total1 = a.total.first, let total2 = b.total.first, !a.total.isEmpty, !b.total.isEmpty else { return nil }
        let dTotal = total2.total - total1.total
        let dIdle = total2.idle - total1.idle
        guard dTotal > 0 else { return nil }
        let usage = max(0, min(100, (1 - dIdle / dTotal) * 100))
        var cores: [Double] = []
        for i in 1..<min(a.total.count, b.total.count) {
            let dT = b.total[i].total - a.total[i].total
            let dI = b.total[i].idle - a.total[i].idle
            cores.append(dT > 0 ? max(0, min(100, (1 - dI / dT) * 100)) : 0)
        }
        return CPUDelta(usage: usage, cores: cores)
    }

    private struct CPUPoint { var total: Double; var idle: Double }

    private func parseCPUStat(_ text: String) -> (total: [CPUPoint], cores: Int) {
        var points: [CPUPoint] = []
        for line in text.split(separator: "\n").map(String.init) {
            let parts = line.split(whereSeparator: { $0 == " " }).compactMap { Double($0) }
            guard line.hasPrefix("cpu"), !parts.isEmpty else { continue }
            // user nice system idle iowait irq softirq steal
            let (user, nice, system, idle, iowait, irq, softirq) = (
                parts[0], parts[1], parts[2], parts[3],
                parts.count > 4 ? parts[4] : 0,
                parts.count > 5 ? parts[5] : 0,
                parts.count > 6 ? parts[6] : 0
            )
            let idleTotal = idle + iowait
            let busy = user + nice + system + irq + softirq
            points.append(CPUPoint(total: busy + idleTotal, idle: idleTotal))
        }
        return (points, max(0, points.count - 1))
    }

    private func parseMemInfo(_ text: String) -> (totalMB: Double, availableMB: Double, cachedMB: Double, swapTotalMB: Double, swapFreeMB: Double)? {
        var values: [String: Double] = [:]
        for line in text.split(separator: "\n").map(String.init) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if parts.count >= 2, let kb = Double(parts[1]) {
                values[parts[0].replacingOccurrences(of: ":", with: "")] = kb / 1024
            }
        }
        guard let total = values["MemTotal"] else { return nil }
        let available = values["MemAvailable"] ?? (total - (values["MemFree"] ?? 0))
        return (total, available, values["Cached"] ?? 0, values["SwapTotal"] ?? 0, values["SwapFree"] ?? 0)
    }

    private func parseLoadAvg(_ text: String) -> (Double, Double, Double) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
        guard parts.count >= 3,
              let a = Double(parts[0]), let b = Double(parts[1]), let c = Double(parts[2]) else { return (-1, -1, -1) }
        return (a, b, c)
    }

    private func parseUptime(_ text: String) -> Double {
        guard let first = text.split(separator: " ").first, let v = Double(first) else { return 0 }
        return v
    }

    private func parseDF(_ text: String) -> [DiskUsage] {
        var result: [DiskUsage] = []
        for line in text.split(separator: "\n").map(String.init) {
            if line.hasPrefix("Filesystem") { continue }
            let parts = line.split(whereSeparator: { $0 == " " }).map(String.init)
            // 支持 7 列（含 fstype，-T）与 POSIX 6 列（df -P）
            guard parts.count >= 6 else { continue }
            // 第一个能转成数字的列就是 1K-blocks；它前面若有第二列就是 fstype
            guard let numericStart = parts.indices.dropFirst().first(where: { Double(parts[$0]) != nil }),
                  numericStart + 3 <= parts.count else { continue }
            guard
                  let sizeK = Double(parts[numericStart]),
                  let usedK = Double(parts[numericStart + 1]),
                  let availK = Double(parts[numericStart + 2]) else { continue }
            let fstype = numericStart == 2 ? parts[1] : ""
            let mountStart = numericStart + 4      // 跳过 Use% 那一列
            let mount = mountStart < parts.count ? parts[mountStart...].joined(separator: " ") : ""
            result.append(DiskUsage(filesystem: parts[0], fstype: fstype,
                                    totalMB: sizeK / 1024, usedMB: usedK / 1024, availMB: availK / 1024,
                                    mountPoint: mount))
        }
        return result
    }

    private func diskIODelta(first: String, second: String, elapsed: Double) -> (read: Double, write: Double)? {
        func parse(_ text: String) -> (read: Double, write: Double)? {
            var readSectors: Double = 0, writeSectors: Double = 0
            var matched = false
            for line in text.split(separator: "\n").map(String.init) {
                let parts = line.split(whereSeparator: { $0 == " " }).map(String.init)
                // major minor name read_io read_merges read_sectors read_ticks write_io ... write_sectors ...
                guard parts.count >= 14, let rs = Double(parts[5]), let ws = Double(parts[9]) else { continue }
                matched = true
                readSectors += rs
                writeSectors += ws
            }
            guard matched else { return nil }
            return (readSectors, writeSectors)
        }
        guard let a = parse(first), let b = parse(second), elapsed > 0 else { return nil }
        // 一个扇区 512 字节
        let readKBps = (b.read - a.read) * 512 / 1024 / elapsed
        let writeKBps = (b.write - a.write) * 512 / 1024 / elapsed
        return (max(0, readKBps), max(0, writeKBps))
    }

    private func netIO(first: String, second: String, elapsed: Double) -> (interfaces: [NetInterfaceStat], totalRx: Double, totalTx: Double) {
        func parse(_ text: String) -> [String: (Double, Double)] {
            var out: [String: (Double, Double)] = [:]
            for line in text.split(separator: "\n").map(String.init) {
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard parts.count >= 10, parts[0].contains(":"), let rx = Double(parts[1]), let tx = Double(parts[9]) else { continue }
                let name = parts[0].replacingOccurrences(of: ":", with: "")
                out[name] = (rx, tx)
            }
            return out
        }
        let a = parse(first), b = parse(second)
        var list: [NetInterfaceStat] = []
        var totalRx: Double = 0, totalTx: Double = 0
        for key in b.keys.sorted() {
            guard let bv = b[key], let av = a[key] else { continue }
            let rx = max(0, (bv.0 - av.0) / 1024 / elapsed)
            let tx = max(0, (bv.1 - av.1) / 1024 / elapsed)
            if key == "lo" { continue }
            list.append(NetInterfaceStat(name: key, rxKBps: rx, txKBps: tx))
            totalRx += rx
            totalTx += tx
        }
        return (list, totalRx, totalTx)
    }

    private func parseThermal(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let milli = Double(trimmed), milli > 100 { return milli / 1000 }
        if trimmed.lowercased().contains("temp=") {
            // vcgencmd: temp=47.2'C
            let cleaned = trimmed.replacingOccurrences(of: "temp=", with: "")
                .replacingOccurrences(of: "'C", with: "")
            return Double(cleaned.trimmingCharacters(in: .whitespaces))
        }
        if let v = Double(trimmed), v > 0 { return v }
        return nil
    }

    /// TOP 进程：CPU% 以 /proc 两次采样差分为准（瞬时占用，每次刷新都会变），
    /// ps 只用来补进程名与内存占比 —— ps 的 %CPU 是进程启动以来的平均值，几乎不动，看着像没刷新。
    private func topProcesses(fromPS psText: String,
                              firstProc: String,
                              secondProc: String,
                              memTotalMB: Double) -> [ProcessStat] {
        let delta = parseProcStatDelta(first: firstProc, second: secondProc, memTotalMB: memTotalMB)
        let psList = parsePS(psText)
        if delta.isEmpty { return psList }

        var commandByPID: [Int: String] = [:]
        var memByPID: [Int: Double] = [:]
        for item in psList {
            commandByPID[item.pid] = item.command
            memByPID[item.pid] = item.memPercent
        }

        var merged: [ProcessStat] = delta.map { item in
            var result = item
            if let command = commandByPID[item.pid], !command.isEmpty { result.command = command }
            if let mem = memByPID[item.pid] { result.memPercent = mem }
            return result
        }
        // ps 里出现、差分表里还没有的进程（刚启动 / 上一次采样还没它）也补上
        let known = Set(merged.map { $0.pid })
        merged.append(contentsOf: psList.filter { !known.contains($0.pid) })

        merged.sort { $0.cpuPercent > $1.cpuPercent }
        return Array(merged.prefix(8))
    }

    /// /proc/<pid>/stat 两次采样差分算 CPU%（BusyBox 上唯一可靠办法）
    private func parseProcStatDelta(first: String, second: String, memTotalMB: Double) -> [ProcessStat] {
        let old = ProcStatTable.parse(first)
        let new = ProcStatTable.parse(second)
        var list: [ProcessStat] = []
        let ticksPerSec = Double(100)   // 绝大多数内核 CONFIG_HZ=100
        for (pid, current) in new {
            guard let previous = old[pid] else { continue }
            let cpuTicks = Double((current.utime + current.stime) - (previous.utime + previous.stime))
            guard cpuTicks >= 0 else { continue }
            let percent = max(0, min(100, cpuTicks / ticksPerSec / 0.9 * 100))
            let memMB = Double(current.rssPages) * 4.0 / 1024.0
            let memPercent = memTotalMB > 0 ? memMB / memTotalMB * 100 : 0
            list.append(ProcessStat(pid: pid, command: current.command, cpuPercent: percent, memPercent: memPercent))
        }
        list.sort { $0.cpuPercent > $1.cpuPercent }
        return Array(list.prefix(8))
    }

    private struct ProcStatTable {
        struct Entry { var utime: Int; var stime: Int; var rssPages: Int; var command: String }
        static func parse(_ text: String) -> [Int: Entry] {
            var table: [Int: Entry] = [:]
            let rows = text.split(separator: "\n").map(String.init)
            var index = 0
            while index + 1 < rows.count {
                let stat = rows[index]
                let cmdline = rows[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                index += 2
                guard let open = stat.firstIndex(of: "("), let close = stat[stat.index(after: open)...].firstIndex(of: ")") else { continue }
                let head = stat[stat.startIndex..<open].trimmingCharacters(in: .whitespaces)
                guard let pid = Int(head) else { continue }
                // 右括号之后的字段才是 utime(14) / stime(15) / rss(24)
                let tail = String(stat[stat.index(after: close)...])
                let fields = tail.split(whereSeparator: { $0 == " " }).filter { !$0.isEmpty }.map(String.init)
                guard fields.count >= 22,
                      let utime = Int(fields[11]), let stime = Int(fields[12]),
                      let rss = Int(fields[21]) else { continue }
                let command = cmdline.isEmpty ? String(stat[stat.index(after: open)..<close]) : cmdline
                table[pid] = Entry(utime: utime, stime: stime, rssPages: rss, command: command)
            }
            return table
        }
    }

    private func parsePS(_ text: String) -> [ProcessStat] {
        var list: [ProcessStat] = []
        for line in text.split(separator: "\n").map(String.init) {
            let parts = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " }).map(String.init)
            guard parts.count >= 4 else { continue }
            // 多种 ps 输出格式都接住：
            // A) 自定义 -o: PID %CPU %MEM COMMAND
            // B) ps aux : USER PID %CPU %MEM VSZ RSS TTY STAT START TIME COMMAND
            var pidStr = parts[0], cpuStr = parts[1], memStr = parts[2], cmdStart = 3
            if Double(parts[0]) == nil, Int(parts[1]) != nil {
                pidStr = parts[1]; cpuStr = parts[2]; memStr = parts[3]; cmdStart = parts.count > 10 ? 10 : 4
            }
            guard let pid = Int(pidStr), let cpu = Double(cpuStr), let mem = Double(memStr) else { continue }
            let cmd = parts[cmdStart...].joined(separator: " ")
            if cmd.isEmpty || cmd == "COMMAND" { continue }
            list.append(ProcessStat(pid: pid, command: cmd, cpuPercent: cpu, memPercent: mem))
        }
        list.sort { $0.cpuPercent > $1.cpuPercent }
        return Array(list.prefix(8))
    }
}
