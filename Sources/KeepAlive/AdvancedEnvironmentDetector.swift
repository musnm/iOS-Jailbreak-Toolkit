//
//  AdvancedEnvironmentDetector.swift
//  越狱 / 巨魔环境探测 + 系统能力自检
//
//  设计原则：
//    * 全部只读探测，不写系统目录、不改任何状态；
//    * 每个探测项独立、互不影响，单项失败只让该项为 false；
//    * 结果带缓存（NSLock 保护），需要实时结果时调 invalidate()。
//
//  能查出来的东西：
//    越狱形态（rootless / roothide / rootful）、TrollStore、
//    是否可读系统文件、dyld 注入库、可疑环境变量、
//    entitlement 自检、能否 fork / 执行子进程、preboot 残留。
//
import Foundation
import UIKit
import Darwin
import Security

/// 一次探测的完整结果，可直接字典化交给 Dart。
public struct AdvancedEnvironment {
    // 越狱形态："none" / "rootless" / "roothide" / "rootful"
    public var jailbreakType: String = "none"
    public var isJailbroken: Bool = false

    // 巨魔
    public var hasTrollStore: Bool = false
    public var trollStoreSigned: Bool = false

    // 包管理器
    public var hasCydia: Bool = false
    public var hasSileo: Bool = false
    public var hasZebra: Bool = false
    public var canOpenSileo: Bool = false
    public var canOpenTrollStore: Bool = false

    // 注入
    public var injectionLibraries: [String] = []
    public var injectionMarkers: [String] = []
    public var environmentHits: [String] = []

    // 沙箱 / 权限
    public var canReadSystemFiles: Bool = false
    public var canWriteSystemArea: Bool = false
    public var sandboxDeniedPaths: [String] = []

    // 进程能力
    public var canFork: Bool = false
    public var canSpawnShell: Bool = false
    public var shellPath: String?

    // 系统信息
    public var systemVersion: String = ""
    public var deviceModel: String = ""
    public var isSimulator: Bool = false
    public var appBundleIdentifier: String = ""

    public init() {}

    /// 给 Dart 的扁平字典。
    public var dictionary: [String: Any] {
        [
            "jailbreakType": jailbreakType,
            "isJailbroken": isJailbroken,
            "hasTrollStore": hasTrollStore,
            "trollStoreSigned": trollStoreSigned,
            "hasCydia": hasCydia,
            "hasSileo": hasSileo,
            "hasZebra": hasZebra,
            "canOpenSileo": canOpenSileo,
            "canOpenTrollStore": canOpenTrollStore,
            "injectionLibraries": injectionLibraries,
            "injectionMarkers": injectionMarkers,
            "environmentHits": environmentHits,
            "canReadSystemFiles": canReadSystemFiles,
            "canWriteSystemArea": canWriteSystemArea,
            "sandboxDeniedPaths": sandboxDeniedPaths,
            "canFork": canFork,
            "canSpawnShell": canSpawnShell,
            "shellPath": shellPath ?? NSNull(),
            "systemVersion": systemVersion,
            "deviceModel": deviceModel,
            "isSimulator": isSimulator,
            "bundleIdentifier": appBundleIdentifier,
        ]
    }

    /// 一行结论，适合直接显示。
    public var summaryLines: [String] {
        var lines: [String] = []
        lines.append(isJailbroken ? "设备状态：已越狱（\(jailbreakType)）" : "设备状态：未越狱")
        if hasTrollStore {
            lines.append(trollStoreSigned ? "巨魔：已安装（通过巨魔签名）" : "巨魔：已安装")
        }
        if canSpawnShell {
            lines.append("系统 shell：可执行（\(shellPath ?? "未知路径")）")
        }
        if !injectionLibraries.isEmpty {
            lines.append("注入库：\(injectionLibraries.count) 个")
        }
        return lines
    }

    /// 每项细节，适合折叠面板。
    public var detailLines: [String] {
        var lines = summaryLines
        lines.append("系统：iOS \(systemVersion)")
        lines.append("机型：\(deviceModel)")
        lines.append("可读系统文件：\(canReadSystemFiles ? "是" : "否")")
        lines.append("可写系统目录：\(canWriteSystemArea ? "是" : "否")")
        lines.append("可 fork：\(canFork ? "是" : "否")")
        if !environmentHits.isEmpty {
            lines.append("环境变量命中：\(environmentHits.joined(separator: ", "))")
        }
        if !sandboxDeniedPaths.isEmpty {
            lines.append("沙箱拒绝：\(sandboxDeniedPaths.joined(separator: ", "))")
        }
        return lines
    }
}

/// 探测主体。所有 static 方法都是无副作用的只读检查。
public final class AdvancedEnvironmentDetector {

    public static let shared = AdvancedEnvironmentDetector()

    private static let lock = NSLock()
    private static var cached: AdvancedEnvironment?

    private init() {}

    // MARK: - 对外

    /// 取探测结果（默认走缓存）。
    public static func detect(cached: Bool = true) -> AdvancedEnvironment {
        lock.lock()
        defer { lock.unlock() }
        if cached, let value = self.cached { return value }
        let value = probeAll()
        self.cached = value
        return value
    }

    /// 丢弃缓存，下次 detect() 重新探测。
    public static func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    // MARK: - 路径常量

    /// rootless 的越狱根。
    private static let rootlessRoots = ["/var/jb", "/var/jb/"]

    /// 包管理器与越狱工具的标志路径。
    private static let packageManagerPaths = [
        "/Applications/Cydia.app",
        "/Applications/Sileo.app",
        "/var/jb/Applications/Sileo.app",
        "/var/lib/dpkg/status",
        "/private/var/lib/apt",
    ]

    /// 注入库：越狱环境常见的 MobileSubstrate / ellekit / libhooker。
    private static let injectionPaths = [
        "/Library/MobileSubstrate/MobileSubstrate.dylib",
        "/usr/lib/libsubstrate.dylib",
        "/var/jb/Library/MobileSubstrate/MobileSubstrate.dylib",
        "/var/jb/usr/lib/libhooker.dylib",
        "/var/jb/usr/lib/libellekit.dylib",
    ]

    /// 巨魔的标志。
    private static let trollStorePaths = [
        "/var/containers/Bundle/Application/.TrollStore",
        "/private/var/containers/Bundle/Application/.TrollStore",
        "/var/mobile/Library/Preferences/com.opa334.TrollStore.plist",
        "/var/mobile/Library/Preferences/com.opa334.TrollStoreHelper.plist",
    ]

    /// 环境变量里出现这些键，基本可以确认处于越狱上下文。
    private static let environmentMarkers = ["JBROOT", "_JBROOT", "DYLD_INSERT_LIBRARIES"]

    /// 沙箱检测用的系统路径：正式环境读不到，越狱后可读。
    private static let systemProbePaths = [
        "/etc/hosts",
        "/private/etc/hosts",
        "/private/var/mobile",
        "/var/preboot",
        "/private/preboot",
        "/System/Library/Frameworks/Security.framework/Security",
    ]

    /// 候选 shell，从最可能可用的开始。
    private static let shellCandidates = [
        "/var/jb/usr/bin/bash",
        "/var/jb/bin/bash",
        "/var/jb/usr/bin/sh",
        "/private/preboot/tmp/sh",
        "/bin/bash",
        "/bin/sh",
    ]

    // MARK: - 基础工具

    private static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    private static func readable(_ path: String) -> Bool {
        var ok = false
        path.withCString { ok = access($0, R_OK) == 0 }
        return ok
    }

    private static func writable(_ path: String) -> Bool {
        var ok = false
        path.withCString { ok = access($0, W_OK) == 0 }
        return ok
    }

    /// 枚举目录，失败返回空。
    private static func directoryNames(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    /// 判断能否打开某个 URL scheme（需要 Info.plist 的 LSApplicationQueriesSchemes）。
    static func canOpenScheme(_ scheme: String) -> Bool {
        guard let url = URL(string: scheme) else { return false }
        if Thread.isMainThread {
            return UIApplication.shared.canOpenURL(url)
        }
        var result = false
        DispatchQueue.main.sync { result = UIApplication.shared.canOpenURL(url) }
        return result
    }

    /// 读文件尾部若干字节，用于判断签名 / 魔数。
    static func fileTail(_ path: String, maxBytes: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        return try? handle.readToEnd()
    }

    /// 当前进程加载的镜像（dyld），用来发现注入。
    static func currentImagePaths() -> [String] {
        var paths: [String] = []
        let count = _dyld_image_count()
        for index in 0..<count {
            if let name = _dyld_get_image_name(index) {
                paths.append(String(cString: name))
            }
        }
        return paths
    }

    /// 从 Security.framework 读自己的 entitlement 值。
    static func entitlementIsTrue(_ key: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        defer { CFRelease(task) }
        guard let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil) else { return false }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return text == "true" || text == "1" }
        return false
    }

    /// 真的 fork 一个进程试试（fork 后立刻退出，不 exec）。
    static func canFork() -> Bool {
        let pid = fork()
        if pid == 0 {
            _exit(0)
        }
        if pid > 0 {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            return true
        }
        return false
    }

    /// 找出一个可执行的 shell。
    static func findShell() -> String? {
        for path in shellCandidates where readable(path) {
            return path
        }
        return nil
    }

    /// 真跑一次 shell 看能不能执行（echo 一个标记）。
    static func spawnProbe(_ shell: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", "echo ioskit-env-probe"]
        process.environment = ["PATH": "/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.contains("ioskit-env-probe") == true
    }

    /// 是不是通过巨魔签名安装的：看有没有 platform-application entitlement。
    static func installedTrollStoreSignedApp() -> Bool {
        entitlementIsTrue("platform-application")
            || entitlementIsTrue("com.apple.private.security.no-container")
    }

    // MARK: - 汇总

    private static func probeAll() -> AdvancedEnvironment {
        var result = AdvancedEnvironment()

        // 系统信息
        result.systemVersion = UIDevice.current.systemVersion
        result.deviceModel = UIDevice.current.model
        result.appBundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        #if targetEnvironment(simulator)
        result.isSimulator = true
        #endif

        // 越狱形态：先看 roothide（最隐蔽），再看 rootless，最后 rootful
        var jbType = "none"
        if ProcessInfo.processInfo.environment["JBROOT"] != nil
            || ProcessInfo.processInfo.environment["_JBROOT"] != nil
            || exists("/var/containers/Bundle/Application/.jbroot")
            || exists("/private/var/containers/Bundle/Application/.jbroot")
            || exists("/var/mobile/.jbroot") {
            jbType = "roothide"
        } else if rootlessRoots.contains(where: exists) {
            jbType = "rootless"
        } else if exists("/Applications/Cydia.app") || exists("/Library/MobileSubstrate/MobileSubstrate.dylib") {
            jbType = "rootful"
        }

        // 包管理器
        result.hasCydia = exists("/Applications/Cydia.app")
        result.hasSileo = exists("/Applications/Sileo.app") || exists("/var/jb/Applications/Sileo.app")
        result.hasZebra = canOpenScheme("zbra://")
        result.canOpenSileo = canOpenScheme("sileo://")
        result.canOpenTrollStore = canOpenScheme("trollstore://")

        // 巨魔
        result.hasTrollStore = trollStorePaths.contains(where: exists)
            || canOpenScheme("trollstore://")
            || directoryNames("/private/var/containers/Bundle/Application").contains(".TrollStore")
        result.trollStoreSigned = installedTrollStoreSignedApp()

        // 包管理器路径命中即视为越狱
        if packageManagerPaths.contains(where: exists) && jbType == "none" {
            jbType = "rootful"
        }
        result.jailbreakType = jbType
        result.isJailbroken = jbType != "none"

        // 注入库：静态路径 + dyld 实际加载
        var injected = injectionPaths.filter(exists)
        for image in currentImagePaths() {
            let lower = image.lowercased()
            if lower.contains("mobilesubstrate") || lower.contains("ellekit")
                || lower.contains("libhooker") || lower.contains("substitute")
                || lower.contains("tweakloader") {
                if !injected.contains(image) { injected.append(image) }
            }
        }
        result.injectionLibraries = injected
        result.injectionMarkers = injectionPaths.filter(exists)

        // 环境变量
        result.environmentHits = environmentMarkers.filter {
            ProcessInfo.processInfo.environment[$0] != nil
        }

        // 沙箱：能不能读系统文件
        result.sandboxDeniedPaths = systemProbePaths.filter { !readable($0) }
        result.canReadSystemFiles = result.sandboxDeniedPaths.count < systemProbePaths.count
        result.canWriteSystemArea = writable("/private/var/mobile") || writable("/var/mobile")

        // 进程能力
        result.canFork = canFork()
        if let shell = findShell() {
            result.shellPath = shell
            result.canSpawnShell = spawnProbe(shell)
        }

        return result
    }
}
