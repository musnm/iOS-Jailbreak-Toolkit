//
//  KeepAliveChannel.swift
//  把 BackgroundKeepAlive 暴露给 Flutter（MethodChannel: "dshgo/keepalive"）
//
//  注册（AppDelegate.swift 的 didFinishLaunchingWithOptions 里）：
//      if let registrar = self.registrar(forPlugin: "KeepAliveChannel") {
//          KeepAliveChannel.register(with: registrar)
//      }
//
//  Dart 端调用：
//      MethodChannel('dshgo/keepalive').invokeMethod('status')
//      ... invokeMethod('setAudio', {'on': true})
//      ... invokeMethod('setLocation', {'on': true})
//      ... invokeMethod('setAll', {'audio': true, 'location': true})
//
//  改通道名：直接改下面的 channelName 常量，Dart 侧同步改。
//
import Flutter
import UIKit

public final class KeepAliveChannel: NSObject, FlutterPlugin {

    /// 与 Dart 侧 MethodChannel 名保持一致
    public static let channelName = "dshgo/keepalive"

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: channelName,
                                           binaryMessenger: registrar.messenger())
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
