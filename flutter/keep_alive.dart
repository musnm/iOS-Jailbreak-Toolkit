//
//  keep_alive.dart
//  BackgroundKeepAlive 的 Dart 侧封装。
//
//  复制到 lib/ 直接用：
//    const ka = BackgroundKeepAlive();
//    await ka.setAudio(true);
//    await ka.setLocation(true);
//    final s = await ka.status();
//
//  没有原生实现（Android / 鸿蒙 / 桌面 / Web）时所有方法静默返回关闭状态，
//  不会抛异常，所以可以无条件调用。
//
//  类名带 Background 前缀：Flutter 的 sliver.dart 已有同名 KeepAlive widget。
//
import 'package:flutter/services.dart';

/// 保活状态快照。
class KeepAliveStatus {
  const KeepAliveStatus({
    this.audio = false,
    this.location = false,
    this.locationAuthorization = 'unknown',
  });

  factory KeepAliveStatus.fromMap(Map<Object?, Object?> raw) => KeepAliveStatus(
        audio: raw['audio'] == true,
        location: raw['location'] == true,
        locationAuthorization: (raw['locationAuthorization'] as String?) ?? 'unknown',
      );

  final bool audio;
  final bool location;

  /// notDetermined / whenInUse / always / denied / restricted / unknown
  final String locationAuthorization;

  /// 需要引导用户去设置里改成「始终允许」
  bool get locationNeedsAlways =>
      locationAuthorization == 'whenInUse' || locationAuthorization == 'notDetermined';

  KeepAliveStatus copyWith({bool? audio, bool? location, String? locationAuthorization}) =>
      KeepAliveStatus(
        audio: audio ?? this.audio,
        location: location ?? this.location,
        locationAuthorization: locationAuthorization ?? this.locationAuthorization,
      );
}

class BackgroundKeepAlive {
  /// 与 iOS 侧 KeepAliveChannel.channelName 保持一致。改这里时原生侧同步改。
  static const String defaultChannelName = 'ioskit/keepalive';

  final MethodChannel _channel;
  const BackgroundKeepAlive({String channelName = defaultChannelName})
      : _channel = MethodChannel(channelName);

  /// 当前状态。没有原生实现时返回全关，不报错。
  Future<KeepAliveStatus> status() async {
    try {
      final raw = await _channel.invokeMethod<Map>('status');
      return KeepAliveStatus.fromMap(raw ?? const {});
    } on MissingPluginException {
      return const KeepAliveStatus();
    } on PlatformException {
      return const KeepAliveStatus();
    }
  }

  /// 静音音频通道。返回是否真的开启成功。
  Future<bool> setAudio(bool on) async {
    try {
      return await _channel.invokeMethod<bool>('setAudio', {'on': on}) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 定位通道。首次开启会弹权限请求；用户没给「始终允许」时返回 false。
  Future<bool> setLocation(bool on) async {
    try {
      return await _channel.invokeMethod<bool>('setLocation', {'on': on}) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 两个通道一起设。返回各自是否成功。
  Future<Map<String, bool>> setAll({bool? audio, bool? location}) async {
    try {
      final raw = await _channel.invokeMethod<Map>('setAll', {
        if (audio != null) 'audio': audio,
        if (location != null) 'location': location,
      });
      return {
        'audio': raw?['audio'] == true,
        'location': raw?['location'] == true,
      };
    } on MissingPluginException {
      return const {'audio': false, 'location': false};
    } on PlatformException {
      return const {'audio': false, 'location': false};
    }
  }

  /// 全部关闭。
  Future<void> stopAll() async {
    try {
      await _channel.invokeMethod<void>('stopAll');
    } on MissingPluginException {
      // ignore
    } on PlatformException {
      // ignore
    }
  }
}
