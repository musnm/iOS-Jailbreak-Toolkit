//
//  SystemShellChannel.swift
//  把系统 shell 能力暴露给 Flutter（MethodChannel: "dshgo/system_shell"）
//
//  只有在越狱 / 巨魔环境下才可能真正执行；正式环境下每次调用都会
//  返回带 error 的字典，不会抛异常，Dart 侧按失败处理即可。
//
//  Dart 端：
//    final ch = MethodChannel('dshgo/system_shell');
//    await ch.invokeMethod('run', {
//      'command': 'ls -la',
//      'cwd': '/var/mobile',        // 可选
//      'env': {'LANG': 'C'},        // 可选，会合并进默认 PATH
//      'timeoutMs': 20000,          // 可选
//      'maxBytes': 262144,          // 可选
//    });
//    await ch.invokeMethod('listDirectory', {'path': '/var/mobile'});
//    await ch.invokeMethod('readBytes', {'path': '/etc/hosts', 'cap': 65536});
//
import Flutter
import UIKit
import Darwin

public final class SystemShellChannel: NSObject, FlutterPlugin {

    /// 与 Dart 侧 MethodChannel 名保持一致
    public static let channelName = "dshgo/system_shell"

    /// 默认 PATH：越狱根优先，其次是系统路径
    static let defaultPath = "/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static let defaultTimeoutMs = 20000
    static let defaultMaxBytes = 256 * 1024
    static let hardMaxBytes = 4 * 1024 * 1024

    /// shell 路径缓存（探测一次就够，路径不会变）
    private static var cachedShell: String?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(SystemShellChannel(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "run":
            guard let command = args["command"] as? String, !command.isEmpty else {
                return result(["error": "command is required"])
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let value = SystemShellChannel.run(
                    command: command,
                    cwd: args["cwd"] as? String,
                    env: args["env"] as? [String: String],
                    timeoutMs: args["timeoutMs"] as? Int ?? SystemShellChannel.defaultTimeoutMs,
                    maxBytes: args["maxBytes"] as? Int ?? SystemShellChannel.defaultMaxBytes)
                DispatchQueue.main.async { result(value) }
            }

        case "listDirectory":
            guard let path = args["path"] as? String, !path.isEmpty else {
                return result(["error": "path is required"])
            }
            result(SystemShellChannel.listDirectory(path: path))

        case "readBytes":
            guard let path = args["path"] as? String, !path.isEmpty else {
                return result(["error": "path is required"])
            }
            let cap = min(args["cap"] as? Int ?? SystemShellChannel.defaultMaxBytes,
                          SystemShellChannel.hardMaxBytes)
            DispatchQueue.global(qos: .userInitiated).async {
                let value = SystemShellChannel.readBytes(path: path, cap: cap)
                DispatchQueue.main.async { result(value) }
            }

        case "shell":
            result(["path": SystemShellChannel.shell() ?? NSNull()])

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - shell 定位

    private static let shellCandidates = [
        "/var/jb/usr/bin/bash",
        "/var/jb/bin/bash",
        "/var/jb/usr/bin/sh",
        "/private/preboot/tmp/sh",
        "/bin/bash",
        "/bin/sh",
    ]

    static func shell() -> String? {
        if let value = cachedShell { return value }
        for path in shellCandidates {
            var ok = false
            path.withCString { ok = access($0, R_OK | X_OK) == 0 }
            if ok {
                cachedShell = path
                return path
            }
        }
        cachedShell = nil
        return nil
    }

    // MARK: - 执行命令

    /// 跑一条命令，超时 / 超长都会截断，绝不无限读。
    /// 返回：{ exitCode, stdout, stderr, truncated, timedOut, shell }
    static func run(command: String, cwd: String?, env: [String: String]?,
                    timeoutMs: Int, maxBytes: Int) -> [String: Any] {
        guard let shell = shell() else {
            return ["error": "no usable shell", "exitCode": -1]
        }
        var variables = ["PATH": defaultPath]
        if let env { for (key, value) in env { variables[key] = value } }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command]
        process.environment = variables
        if let cwd, !cwd.isEmpty {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue {
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            } else {
                return ["error": "cwd is not a directory: \(cwd)", "exitCode": -1]
            }
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let limit = min(max(maxBytes, 1024), hardMaxBytes)
        let collector = OutputCollector(limit: limit)

        // 边读边截断，超过上限就停止累积，避免读爆内存
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData, isError: false)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData, isError: true)
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return ["error": "spawn failed: \(error.localizedDescription)", "exitCode": -1, "shell": shell]
        }

        // 超时看门狗
        let deadline = DispatchTime.now() + .milliseconds(max(timeoutMs, 100))
        var timedOut = false
        while process.isRunning {
            if DispatchTime.now() >= deadline {
                timedOut = true
                process.terminate()
                break
            }
            usleep(20_000)
        }
        process.waitUntilExit()

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        collector.append(outPipe.fileHandleForReading.readDataToEndOfFile(), isError: false)
        collector.append(errPipe.fileHandleForReading.readDataToEndOfFile(), isError: true)

        let snapshot = collector.snapshot()
        return [
            "exitCode": Int(process.terminationStatus),
            "stdout": snapshot.stdout,
            "stderr": snapshot.stderr,
            "truncated": snapshot.truncated,
            "timedOut": timedOut,
            "shell": shell,
        ]
    }

    // MARK: - 目录

    static func listDirectory(path: String) -> [String: Any] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return ["error": "not a directory: \(path)"]
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return ["error": "cannot list: \(path)"]
        }
        var entries: [[String: Any]] = []
        entries.reserveCapacity(names.count)
        for name in names.sorted() {
            let full = (path as NSString).appendingPathComponent(name)
            var entry: [String: Any] = ["name": name]
            var dir: ObjCBool = false
            if FileManager.default.fileExists(atPath: full, isDirectory: &dir) {
                entry["isDirectory"] = dir.boolValue
            }
            if let attributes = try? FileManager.default.attributesOfItem(atPath: full) {
                if let size = attributes[.size] as? NSNumber { entry["size"] = size.intValue }
                if let date = attributes[.modificationDate] as? Date {
                    entry["modified"] = date.timeIntervalSince1970
                }
                if let type = attributes[.type] as? FileAttributeType, type == .typeSymbolicLink {
                    entry["isSymlink"] = true
                }
            }
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: full) {
                entry["target"] = destination
            }
            entries.append(entry)
        }
        return ["path": path, "entries": entries]
    }

    // MARK: - 读文件

    /// 读文件前 cap 字节。二进制内容以 base64 返回，文本内容同时给字符串。
    static func readBytes(path: String, cap: Int) -> [String: Any] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return ["error": "not a file: \(path)"]
        }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return ["error": "cannot open: \(path)"]
        }
        defer { try? handle.close() }
        let limit = min(max(cap, 1), hardMaxBytes)
        let data = handle.readData(ofLength: limit + 1)
        let truncated = data.count > limit
        let payload = truncated ? data.prefix(limit) : data
        let total = (try? handle.seekToEnd()) ?? UInt64(payload.count)
        var output: [String: Any] = [
            "path": path,
            "size": Int(total),
            "truncated": truncated,
            "base64": payload.base64EncodedString(),
        ]
        if let text = String(data: payload, encoding: .utf8) {
            output["text"] = text
        }
        return output
    }
}

/// 有上限的输出收集器。读满上限后丢弃后续数据并打上 truncated。
private final class OutputCollector {
    private let limit: Int
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var truncated = false

    init(limit: Int) { self.limit = limit }

    func append(_ data: Data, isError: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var target = isError ? stderr : stdout
        let room = limit - target.count
        if room <= 0 {
            truncated = true
        } else if data.count > room {
            target.append(data.prefix(room))
            truncated = true
        } else {
            target.append(data)
        }
        if isError { stderr = target } else { stdout = target }
    }

    func snapshot() -> (stdout: String, stderr: String, truncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (
            String(data: stdout, encoding: .utf8) ?? "",
            String(data: stderr, encoding: .utf8) ?? "",
            truncated
        )
    }
}
