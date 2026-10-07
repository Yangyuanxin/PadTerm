import Charts
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var store: AppState
    let host: HostConfig

    @ObservedObject private var viewModel: MetricsViewModel

    init(host: HostConfig, viewModel: MetricsViewModel) {
        self.host = host
        self._viewModel = ObservedObject(wrappedValue: viewModel)
    }

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerBar
                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }
                kpiGrid
                if let snapshot = viewModel.current {
                    cpuSection(snapshot)
                    memorySection(snapshot)
                    ioSection
                    diskSection(snapshot)
                    processSection(snapshot)
                    if !snapshot.warnings.isEmpty { warningsSection(snapshot.warnings) }
                } else {
                    VStack(spacing: 6) {
                        ProgressView()
                        Text(viewModel.isBusy ? "正在采集…" : "尚未取到数据")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("首次采样约需 2 秒；若长时间无数据，请看下方采集提示")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                    // 采集提示不再依赖 current，首采失败也能看见原因
                    if let error = viewModel.errorMessage {
                        warningsSection([error])
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("\(host.name) · 监控")
        .toolbar { toolbarContent }
        .onAppear { if !viewModel.isRunning { viewModel.start() } }
    }

    // MARK: - 顶部控制条

    private var headerBar: some View {
        HStack(spacing: 12) {
            Label {
                Text(viewModel.isRunning ? "每 \(String(format: "%.1f", viewModel.interval))s 自动刷新" : "已暂停")
                    .font(.subheadline)
            } icon: {
                Image(systemName: viewModel.isRunning ? "arrow.triangle.2.circlepath" : "pause.circle")
                    .foregroundStyle(viewModel.isRunning ? .green : .secondary)
            }
            Spacer()
            Picker("间隔", selection: $viewModel.interval) {
                Text("1s").tag(1.0)
                Text("2s").tag(2.0)
                Text("5s").tag(5.0)
                Text("10s").tag(10.0)
            }
            .frame(width: 130)
            .onChange(of: viewModel.interval) { _, _ in
                viewModel.stop()
                viewModel.start()
            }
            Button {
                viewModel.stop()
                viewModel.start()
            } label: { Label("重启采集", systemImage: "arrow.counterclockwise") }

            Button {
                if viewModel.isRunning { viewModel.stop() } else { viewModel.start() }
            } label: { Label(viewModel.isRunning ? "暂停" : "继续", systemImage: viewModel.isRunning ? "pause.fill" : "play.fill") }
            .buttonStyle(.borderedProminent)
        }
    }

    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { viewModel.refreshOnce() } label: { Image(systemName: "arrow.clockwise") }
                .disabled(viewModel.isBusy)
        }
    }

    // MARK: - KPI 卡片

    private var kpiGrid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            let snapshot = viewModel.current ?? .empty
            KPICard(title: "CPU", value: String(format: "%.1f%%", snapshot.cpuTotalPercent),
                    systemImage: "cpu", tint: .blue,
                    detail: "负载 \(String(format: "%.2f", snapshot.loadAvg1)) / \(String(format: "%.2f", snapshot.loadAvg5))")
            KPICard(title: "内存", value: String(format: "%.1f%%", snapshot.memUsedPercent),
                    systemImage: "memorychip", tint: .purple,
                    detail: String(format: "%.0f / %.0f MB", snapshot.memUsedMB, snapshot.memTotalMB))
            KPICard(title: "磁盘读取", value: formatRate(snapshot.diskReadKBps),
                    systemImage: "internaldrive", tint: .orange,
                    detail: "写入 \(formatRate(snapshot.diskWriteKBps))")
            KPICard(title: "网络下行", value: formatRate(snapshot.netRxKBps),
                    systemImage: "arrow.down.circle", tint: .green,
                    detail: "上行 \(formatRate(snapshot.netTxKBps))")
            KPICard(title: "温度", value: snapshot.cpuTempC.map { String(format: "%.1f°C", $0) } ?? "—",
                    systemImage: "thermometer", tint: (snapshot.cpuTempC ?? 0) > 75 ? .red : .cyan,
                    detail: "交换机/SoC 热区")
            KPICard(title: "运行时长", value: snapshot.uptimeText,
                    systemImage: "clock", tint: .indigo, detail: "swap \(String(format: "%.0f", snapshot.swapUsedMB)) MB")
        }
    }

    // MARK: - 各图表分区

    private func cpuSection(_ snapshot: MetricSnapshot) -> some View {
        CardBox(title: "CPU 占用", systemImage: "cpu") {
            VStack(spacing: 10) {
                chartFrame(height: 180) {
                    Chart(viewModel.history) { snap in
                        LineMark(
                            x: .value("时间", snap.timestamp),
                            y: .value("占用", snap.cpuTotalPercent),
                            series: .value("series", "总CPU")
                        )
                        .foregroundStyle(.blue)
                        .interpolationMethod(.catmullRom)
                        AreaMark(
                            x: .value("时间", snap.timestamp),
                            y: .value("占用", snap.cpuTotalPercent),
                            series: .value("series", "总CPU")
                        )
                        .foregroundStyle(LinearGradient(colors: [.blue.opacity(0.35), .clear],
                                                        startPoint: .top, endPoint: .bottom))
                        LineMark(
                            x: .value("时间", snap.timestamp),
                            y: .value("负载", snap.loadAvg1 * 10),
                            series: .value("series", "负载x10")
                        )
                        .foregroundStyle(.orange.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                    .chartYScale(domain: 0...100)
                    .chartLegend(position: .bottom, alignment: .leading)
                }
                if snapshot.cores.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .bottom, spacing: 6) {
                            ForEach(snapshot.cores) { core in
                                VStack(spacing: 4) {
                                    Text(String(format: "%.0f", core.percent))
                                        .font(.caption2)
                                    Capsule()
                                        .fill(core.percent > 80 ? Color.red : (core.percent > 50 ? Color.orange : Color.blue))
                                        .frame(width: 26, height: max(4, CGFloat(core.percent) * 0.9))
                                    Text("C\(core.index)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func memorySection(_ snapshot: MetricSnapshot) -> some View {
        CardBox(title: "内存 / Swap", systemImage: "memorychip") {
            VStack(spacing: 12) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        metricRow("已用", String(format: "%.0f MB", snapshot.memUsedMB), .purple)
                        metricRow("缓存/缓冲", String(format: "%.0f MB", snapshot.memCachedMB), .teal)
                        metricRow("可用", String(format: "%.0f MB", max(0, snapshot.memTotalMB - snapshot.memUsedMB)), .green)
                        metricRow("Swap", String(format: "%.0f / %.0f MB", snapshot.swapUsedMB, snapshot.swapTotalMB), .orange)
                    }
                    .frame(maxWidth: 220, alignment: .leading)
                    chartFrame(height: 150) {
                        Chart(viewModel.history) { snap in
                            LineMark(x: .value("时间", snap.timestamp),
                                     y: .value("已用%", snap.memUsedPercent))
                            .foregroundStyle(.purple)
                        }
                        .chartYScale(domain: 0...100)
                        .chartYAxis { AxisMarks(position: .leading) }
                    }
                }
            }
        }
    }

    private var ioSection: some View {
        CardBox(title: "磁盘 IO 与网络速率 (KB/s)", systemImage: "arrow.left.arrow.right") {
            chartFrame(height: 190) {
                Chart {
                    ForEach(viewModel.history) { snap in
                        LineMark(x: .value("时间", snap.timestamp),
                                 y: .value("速率", snap.diskReadKBps),
                                 series: .value("系列", "磁盘读"))
                        .foregroundStyle(.orange)
                        LineMark(x: .value("时间", snap.timestamp),
                                 y: .value("速率", snap.diskWriteKBps),
                                 series: .value("系列", "磁盘写"))
                        .foregroundStyle(.pink)
                        LineMark(x: .value("时间", snap.timestamp),
                                 y: .value("速率", snap.netRxKBps),
                                 series: .value("系列", "网络下行"))
                        .foregroundStyle(.green)
                        LineMark(x: .value("时间", snap.timestamp),
                                 y: .value("速率", snap.netTxKBps),
                                 series: .value("系列", "网络上行"))
                        .foregroundStyle(.blue)
                    }
                }
                .chartLegend(position: .bottom, alignment: .leading)
                .chartYAxis { AxisMarks(position: .leading) }
            }
        }
    }

    /// 容量自适应：小于 1GB 用 MB，否则用 GB
    private static func humanMB(_ mb: Double) -> String {
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }

    private func diskSection(_ snapshot: MetricSnapshot) -> some View {
        CardBox(title: "存储分区", systemImage: "internaldrive") {
            VStack(alignment: .leading, spacing: 8) {
                // 与 df -h 一致的列：文件系统 类型 容量 已用 可用 已用% 挂载点
                dfRow(filesystem: "文件系统", fstype: "类型", size: "容量",
                      used: "已用", avail: "可用", percent: "已用%", mount: "挂载点")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Divider()
                ForEach(snapshot.disks) { disk in
                    VStack(alignment: .leading, spacing: 4) {
                        dfRow(filesystem: disk.filesystem,
                              fstype: disk.fstype.isEmpty ? "-" : disk.fstype,
                              size: Self.dfHuman(disk.totalMB),
                              used: Self.dfHuman(disk.usedMB),
                              avail: Self.dfHuman(disk.availMB),
                              percent: String(format: "%.0f%%", disk.usedPercent),
                              mount: disk.mountPoint,
                              percentColor: disk.usedPercent > 90 ? .red : (disk.usedPercent > 70 ? .orange : .primary))
                        ProgressView(value: disk.usedPercent / 100)
                            .tint(disk.usedPercent > 90 ? .red : (disk.usedPercent > 70 ? .orange : .blue))
                    }
                }
                if snapshot.disks.isEmpty { Text("未取到分区信息").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func dfRow(filesystem: String, fstype: String, size: String, used: String,
                       avail: String, percent: String, mount: String,
                       percentColor: Color = .primary) -> some View {
        HStack(spacing: 8) {
            Text(filesystem).frame(minWidth: 110, maxWidth: 150, alignment: .leading).lineLimit(1)
            Text(fstype).frame(width: 52, alignment: .leading).lineLimit(1)
            Text(size).frame(width: 60, alignment: .trailing)
            Text(used).frame(width: 60, alignment: .trailing)
            Text(avail).frame(width: 60, alignment: .trailing)
            Text(percent).frame(width: 52, alignment: .trailing).foregroundStyle(percentColor)
            Text(mount).frame(minWidth: 90, alignment: .leading).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.caption.monospaced())
    }

    /// df -h 风格容量：T / G / M
    private static func dfHuman(_ mb: Double) -> String {
        let gb = mb / 1024
        if gb >= 1024 { return String(format: "%.1fT", gb / 1024) }
        if gb >= 1 { return String(format: "%.1fG", gb) }
        return String(format: "%.0fM", mb)
    }

    private func processSection(_ snapshot: MetricSnapshot) -> some View {
        CardBox(title: "资源占用 TOP 进程", systemImage: "list.number") {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.green)
                    Text("更新于 \(snapshot.timestamp.formatted(.dateTime.hour().minute().second())) · CPU% 为两次采样的瞬时占用")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                HStack {
                    Text("PID").frame(width: 60, alignment: .leading)
                    Text("进程").frame(maxWidth: .infinity, alignment: .leading)
                    Text("CPU%").frame(width: 60, alignment: .trailing)
                    Text("MEM%").frame(width: 60, alignment: .trailing)
                }
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                Divider()
                ForEach(snapshot.topProcesses) { process in
                    HStack {
                        Text("\(process.pid)").frame(width: 60, alignment: .leading)
                        Text(process.command).frame(maxWidth: .infinity, alignment: .leading)
                        Text(String(format: "%.1f", process.cpuPercent)).frame(width: 60, alignment: .trailing)
                        Text(String(format: "%.1f", process.memPercent)).frame(width: 60, alignment: .trailing)
                    }
                    .font(.caption.monospaced())
                }
                if snapshot.topProcesses.isEmpty { Text("未取到进程列表").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func warningsSection(_ warnings: [String]) -> some View {
        CardBox(title: "采集提示", systemImage: "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(warnings, id: \.self) { Text("· \($0)").font(.caption) }
            }
        }
    }

    // MARK: - 辅助

    private func chartFrame<Content: View>(height: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(height: height)
            .frame(maxWidth: .infinity)
    }

    private func metricRow(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.caption)
            Spacer()
            Text(value).font(.caption.monospaced())
        }
    }

    private func formatRate(_ kbPerSecond: Double) -> String {
        if kbPerSecond >= 1024 { return String(format: "%.2f MB/s", kbPerSecond / 1024) }
        return String(format: "%.0f KB/s", kbPerSecond)
    }
}

// MARK: - 通用小部件

struct CardBox<Content: View>: View {
    var title: String
    var systemImage: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct KPICard: View {
    var title: String
    var value: String
    var systemImage: String
    var tint: Color
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 96)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
