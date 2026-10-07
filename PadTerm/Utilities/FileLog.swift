//
//  FileLog.swift
//  PadTerm
//
//  输入路径排查用的轻量文件日志（/tmp/padterm_input.log）
//  无条件记录，便于远程诊断键盘事件是否到达终端视图
//

import Foundation

enum FileLog {
    // iOS 沙箱里写不了 /tmp，落到 Documents 容器（Mac Catalyst 上仍可读）
    static let url: URL = {
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            return docs.appendingPathComponent("padterm_input.log")
        }
        return URL(fileURLWithPath: "/tmp/padterm_input.log")
    }()
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func log(_ line: String) {
        let text = "\(formatter.string(from: Date())) \(line)\n"
        let path = url.path
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            if let data = text.data(using: .utf8) { handle.write(data) }
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    static func clear() {
        try? "".write(toFile: url.path, atomically: true, encoding: .utf8)
    }
}
