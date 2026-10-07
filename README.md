# PadTerm — iPhone / iPad 上的 SSH 终端 + 设备监控 + AI 分析助手

在 iPhone / iPad / Mac 上通过 SSH 管理任意 Linux 设备：交互式 shell、指标可视化、AI 会话分析。
面向 iOS 17+ / iPadOS 17+，并支持 Mac Catalyst。

## 许可与版权

Copyright © 2026 杨源鑫 (Bruce.yang)

本项目以 **GNU General Public License v3.0** 发布，完整条款见 [LICENSE](./LICENSE)。

- 出品：嵌入式应用研究院
- 技术博客：Bruce.yang的嵌入式之旅
- GitHub：@Yangyuanxin

## 功能

1. **终端**：真实 PTY 交互式 shell。
2. **监控**：CPU（总量 + 每核）、负载、内存/Swap/缓存、存储分区、磁盘 IO 速率、网络下行/上行速率、温度、运行时长、TOP 进程。自带时间轴曲线，1/2/5/10 秒轮询可切。
3. **AI 会话**：
   - **设备问答**：把该设备的最新指标快照作为上下文发给模型；回复里的 `bash` 代码块可一键丢回终端执行。
   - **普通问答**：不携带设备上下文。
   - 使用 OpenAI 兼容 `/v1/chat/completions` 流式接口，可填 OpenAI / DeepSeek / 通义 / Moonshot / 本地 Ollama、LM Studio。

## 工程结构

```
project.yml               XcodeGen 工程描述（依赖 + 构建设置）
PadTerm.xcodeproj/        由 xcodegen 生成（改代码不需要重新生成）
PadTerm/
  App/                    入口与全局状态
  Models/                 设备配置、指标模型
  Services/               SSHService、MetricsCollector、AIClient、Keychain
  Terminal/               TerminalBuffer（ANSI 屏幕模拟）
  ViewModels/             终端 / 监控视图模型
  Views/                  根视图、终端页、监控页、AI 页、设备列表、设置
```

## 编译与运行

1. 打开 `PadTerm.xcodeproj`（Xcode 27 / Swift 6.4）。
2. 首次打开会自动拉取 SwiftPM 依赖：`apple/swift-nio-ssh 0.9.1`、`apple/swift-nio 2.99.0`（网络不稳可在 Xcode 里重试）。
3. 左侧 Target `PadTerm` → Signing & Capabilities，选你的 Team（免费账号也行，签名 7 天有效）。
4. iPad 用数据线连接并信任本机，选中该设备后 Run。

> 若改到工程结构（新增依赖/构建选项），改 `project.yml` 后重新执行 `xcodegen generate`。

## 采集原理（无 agent）

指标全部通过一条 SSH 命令读取 `/proc` 文件系统后本地解析，不在被控设备安装任何 agent：

| 指标 | 数据来源 |
| --- | --- |
| CPU 总量 / 每核 | `/proc/stat` 两次采样差值 |
| 内存 / Swap / 缓存 | `/proc/meminfo` |
| 负载、运行时长 | `/proc/loadavg`、`/proc/uptime` |
| 磁盘 IO 速率 | `/proc/diskstats` 两次采样（扇区 ×512B） |
| 网络速率 | `/proc/net/dev` 两次采样 |
| 分区容量 | `df -PT`（与 `df -h` 相同的分区列表，含 tmpfs） |
| 温度 | `/sys/class/thermal/thermal_zone0/temp`，失败回退 `vcgencmd measure_temp` |
| TOP 进程 | `/proc/<pid>/stat` 两次采样差分算瞬时 CPU%，进程名取自 `ps -eo pid,pcpu,pmem,comm` |

每一项独立容错：某条命令不被支持只会让对应指标缺失并在「采集提示」中标出，不会整页失败。

## 一键编译安装

```bash
./build_ipad.sh      # 安装到已连接的 iPad（脚本内写死了 UDID，按你的设备改）
./build_iphone.sh    # 安装到已连接的 iPhone
./build_mac.sh       # 编译 Mac Catalyst 版本
```

## 安全

- SSH 密码存 iOS **钥匙串（Keychain）**，不写入 `hosts.json`。
- 主机密钥采用**首次信任（TOFU）**，与常见 SSH 客户端一致；App 不做自动执行的修改类操作，AI 给的命令需你手动点击才会执行。
- AI 的 Base URL / API Key **只保存在本机 UserDefaults**，不写入源码、不上传、不随备份分享；使用前请在「设置 → AI 接口」自行填写，预设里不含任何人的密钥。

## 已知限制

- 认证方式当前以**密码**为主；密钥认证暂未在 UI 中开放。
- 未追求 VT 全兼容：`vim`/`tmux` 等全屏应用的渲染可能不完整（常规 shell、`top`、`journalctl`、`htop` 可用）。
