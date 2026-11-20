//
//  AdvancedEnvironmentChannel.swift
//  把环境探测暴露给 Flutter（MethodChannel: "dshgo/advanced_env"）
//
//  Dart 端：
//    final ch = MethodChannel('dshgo/advanced_env');
//    final env = await ch.invokeMethod('detect');              // 走缓存
//    final fresh = await ch.invokeMethod('detect', {'cached': false});
//    await ch.invokeMethod('invalidate');                      // 清缓存
//    final lines = await ch.invokeMethod('summary');           // 一行结论
//    final detail = await ch.invokeMethod('detail');           // 详细项
//
import Flutter
import UIKit

public final class AdvancedEnvironmentChannel: NSObject, FlutterPlugin {

    /// 与 Dart 侧 MethodChannel 名保持一致
    public static let channelName = "dshgo/advanced_env"

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
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
