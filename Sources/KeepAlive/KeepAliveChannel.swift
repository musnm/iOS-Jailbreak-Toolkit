//
//  KeepAliveChannel.swift
//  把 BackgroundKeepAlive 暴露给 Flutter（默认 MethodChannel: "ioskit/keepalive"）
//
//  注册（AppDelegate.swift 的 didFinishLaunchingWithOptions 里）：
//      if let registrar = self.registrar(forPlugin: "KeepAliveChannel") {
//          KeepAliveChannel.register(with: registrar)
//      }
//
//  自定义通道名（推荐，避免同机多 App 冲突）：
//      KeepAliveChannel.register(with: registrar, name: "yourapp/keepalive")
//
//  Dart 端调用：
//      MethodChannel('ioskit/keepalive').invokeMethod('status')
//      ... invokeMethod('setAudio', {'on': true})
//      ... invokeMethod('setLocation', {'on': true})
//      ... invokeMethod('setAll', {'audio': true, 'location': true})
//
import Flutter
import UIKit

public final class KeepAliveChannel: NSObject, FlutterPlugin {

    /// Dart 侧的默认通道名。可改。
    public static let channelName = "ioskit/keepalive"

    public static func register(with registrar: FlutterPluginRegistrar) {
        register(with: registrar, name: channelName)
    }

    /// 用自定义通道名注册。
    public static func register(with registrar: FlutterPluginRegistrar, name: String) {
        let channel = FlutterMethodChannel(name: name, binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(KeepAliveChannel(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let ka = BackgroundKeepAlive.shared
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "status":
            result(ka.status())
        case "setAudio":
            result(ka.setAudioKeepAlive(args["on"] as? Bool ?? false))
        case "setLocation":
            result(ka.setLocationKeepAlive(args["on"] as? Bool ?? false))
        case "setAll":
            let a = ka.setAudioKeepAlive(args["audio"] as? Bool ?? false)
            let l = ka.setLocationKeepAlive(args["location"] as? Bool ?? false)
            result(["audio": a, "location": l])
        case "stopAll":
            ka.stopAll()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
