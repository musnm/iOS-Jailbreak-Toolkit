//
//  AdvancedEnvironmentChannel.swift
//  把环境探测暴露给 Flutter（默认 MethodChannel: "ioskit/advanced_env"）
//
//  自定义通道名：
//      AdvancedEnvironmentChannel.register(with: registrar, name: "yourapp/advanced_env")
//
//  Dart 端：
//    final env = await AdvancedEnvironment.probe();                    // 走缓存
//    final fresh = await AdvancedEnvironment.probe(cached: false);     // 强制重探
//    await AdvancedEnvironment.invalidate();                           // 清缓存
//    final lines = await AdvancedEnvironment.summary();                // 一行结论
//    final detail = await AdvancedEnvironment.detail();                // 详细项
//
import Flutter
import UIKit

public final class AdvancedEnvironmentChannel: NSObject, FlutterPlugin {

    /// Dart 侧的默认通道名。可改。
    public static let channelName = "ioskit/advanced_env"

    public static func register(with registrar: FlutterPluginRegistrar) {
        register(with: registrar, name: channelName)
    }

    /// 用自定义通道名注册。
    public static func register(with registrar: FlutterPluginRegistrar, name: String) {
        let channel = FlutterMethodChannel(name: name, binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(AdvancedEnvironmentChannel(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "detect":
            let useCache = args["cached"] as? Bool ?? true
            // 探测里有 fork / spawn，不能在主线程做
            DispatchQueue.global(qos: .userInitiated).async {
                let environment = AdvancedEnvironmentDetector.detect(cached: useCache)
                DispatchQueue.main.async { result(environment.dictionary) }
            }

        case "invalidate":
            AdvancedEnvironmentDetector.invalidate()
            result(nil)

        case "summary":
            DispatchQueue.global(qos: .userInitiated).async {
                let environment = AdvancedEnvironmentDetector.detect()
                DispatchQueue.main.async { result(environment.summaryLines) }
            }

        case "detail":
            DispatchQueue.global(qos: .userInitiated).async {
                let environment = AdvancedEnvironmentDetector.detect()
                DispatchQueue.main.async { result(environment.detailLines) }
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
