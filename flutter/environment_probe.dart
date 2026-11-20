// environment_probe.dart
// 环境探测 + 系统 shell 的 Dart 封装。
//
// 复制到 lib/ 后直接用：
//   final env = await AdvancedEnvironment.probe();
//   if (env.isJailbroken) print('越狱形态: ${env.jailbreakType}');
//   final out = await SystemShell.run('ls -la /var/mobile');
//
// 两个通道名必须和 Swift 侧一致（下面是默认值，可在调用时传 channelName 覆盖）：
//   ioskit/advanced_env    ioskit/system_shell

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/services.dart';

/// 环境探测结果。字段与 Swift 侧 AdvancedEnvironment.dictionary 一一对应。
class AdvancedEnvironment {
  const AdvancedEnvironment(this.raw);

  final Map<String, dynamic> raw;

  /// 越狱形态："none" / "rootless" / "roothide" / "rootful"
  String get jailbreakType => raw['jailbreakType'] as String? ?? 'none';
  bool get isJailbroken => raw['isJailbroken'] as bool? ?? false;

  bool get hasTrollStore => raw['hasTrollStore'] as bool? ?? false;
  bool get trollStoreSigned => raw['trollStoreSigned'] as bool? ?? false;

  bool get hasCydia => raw['hasCydia'] as bool? ?? false;
  bool get hasSileo => raw['hasSileo'] as bool? ?? false;
  bool get hasZebra => raw['hasZebra'] as bool? ?? false;
  bool get canOpenSileo => raw['canOpenSileo'] as bool? ?? false;
  bool get canOpenTrollStore => raw['canOpenTrollStore'] as bool? ?? false;

  List<String> get injectionLibraries =>
      (raw['injectionLibraries'] as List?)?.cast<String>() ?? const [];
  List<String> get injectionMarkers =>
      (raw['injectionMarkers'] as List?)?.cast<String>() ?? const [];
  List<String> get environmentHits =>
      (raw['environmentHits'] as List?)?.cast<String>() ?? const [];

  bool get canReadSystemFiles => raw['canReadSystemFiles'] as bool? ?? false;
  bool get canWriteSystemArea => raw['canWriteSystemArea'] as bool? ?? false;
  List<String> get sandboxDeniedPaths =>
      (raw['sandboxDeniedPaths'] as List?)?.cast<String>() ?? const [];

  bool get canFork => raw['canFork'] as bool? ?? false;
  bool get canSpawnShell => raw['canSpawnShell'] as bool? ?? false;
  String? get shellPath => raw['shellPath'] as String?;

  String get systemVersion => raw['systemVersion'] as String? ?? '';
  String get deviceModel => raw['deviceModel'] as String? ?? '';
  bool get isSimulator => raw['isSimulator'] as bool? ?? false;
  String get bundleIdentifier => raw['bundleIdentifier'] as String? ?? '';

  /// 一行结论，适合显示在设置页。
  String get headline {
    if (!isJailbroken && !hasTrollStore) return '未越狱';
    final parts = <String>[];
    if (isJailbroken) parts.add('已越狱（$jailbreakType）');
    if (hasTrollStore) parts.add(trollStoreSigned ? '巨魔（签名）' : '巨魔');
    if (canSpawnShell) parts.add('可执行系统命令');
    return parts.join(' · ');
  }

  /// 与 iOS 侧 AdvancedEnvironmentChannel.channelName 保持一致。改这里时原生侧同步改。
  static const String defaultChannelName = 'ioskit/advanced_env';

  /// 取探测结果。[cached] 为 false 时强制重新探测。
  static Future<AdvancedEnvironment> probe({
    bool cached = true,
    String channelName = defaultChannelName,
  }) async {
    final value =
        await MethodChannel(channelName).invokeMethod<Map>('detect', {'cached': cached});
    return AdvancedEnvironment(Map<String, dynamic>.from(value ?? const {}));
  }

  /// 清掉缓存，下次 probe() 重新探测。
  static Future<void> invalidate({String channelName = defaultChannelName}) =>
      MethodChannel(channelName).invokeMethod<void>('invalidate');

  /// 一行结论（原生侧生成）。
  static Future<List<String>> summary({String channelName = defaultChannelName}) async {
    final value = await MethodChannel(channelName).invokeMethod<List>('summary');
    return (value ?? const []).cast<String>();
  }

  /// 每项细节。
  static Future<List<String>> detail({String channelName = defaultChannelName}) async {
    final value = await MethodChannel(channelName).invokeMethod<List>('detail');
    return (value ?? const []).cast<String>();
  }
}

/// 系统 shell 的执行结果。
class ShellResult {
  const ShellResult(this.raw);

  final Map<String, dynamic> raw;

  String? get error => raw['error'] as String?;
  bool get ok => error == null && exitCode == 0;
  int get exitCode => raw['exitCode'] as int? ?? -1;
  String get stdout => raw['stdout'] as String? ?? '';
  String get stderr => raw['stderr'] as String? ?? '';
  bool get truncated => raw['truncated'] as bool? ?? false;
  bool get timedOut => raw['timedOut'] as bool? ?? false;
  String? get shell => raw['shell'] as String?;

  @override
  String toString() => ok ? stdout : (error ?? 'exit $exitCode: $stderr');
}

/// 目录项。
class DirEntry {
  const DirEntry(this.raw);

  final Map<String, dynamic> raw;
  String get name => raw['name'] as String? ?? '';
  bool get isDirectory => raw['isDirectory'] as bool? ?? false;
  bool get isSymlink => raw['isSymlink'] as bool? ?? false;
  String? get target => raw['target'] as String?;
  int get size => raw['size'] as int? ?? 0;
  double? get modified => (raw['modified'] as num?)?.toDouble();
}

/// 系统 shell。只有越狱 / 巨魔环境下的调用才可能成功。
class SystemShell {
  /// 与 iOS 侧 SystemShellChannel.channelName 保持一致。改这里时原生侧同步改。
  static const String defaultChannelName = 'ioskit/system_shell';

  /// 当前可用的 shell 路径，null 表示没有。
  static Future<String?> shellPath({String channelName = defaultChannelName}) async {
    final value = await MethodChannel(channelName).invokeMethod<Map>('shell');
    return value?['path'] as String?;
  }

  /// 执行命令。
  static Future<ShellResult> run(
    String command, {
    String? cwd,
    Map<String, String>? env,
    int timeoutMs = 20000,
    int maxBytes = 256 * 1024,
    String channelName = defaultChannelName,
  }) async {
    final value = await MethodChannel(channelName).invokeMethod<Map>('run', {
      'command': command,
      if (cwd != null) 'cwd': cwd,
      if (env != null) 'env': env,
      'timeoutMs': timeoutMs,
      'maxBytes': maxBytes,
    });
    return ShellResult(Map<String, dynamic>.from(value ?? const {}));
  }

  /// 列目录。
  static Future<List<DirEntry>> listDirectory(
    String path, {
    String channelName = defaultChannelName,
  }) async {
    final value =
        await MethodChannel(channelName).invokeMethod<Map>('listDirectory', {'path': path});
    final entries = (value?['entries'] as List?) ?? const [];
    return entries
        .map((e) => DirEntry(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// 读文件（最多 cap 字节）。文本内容在 text 字段，二进制在 base64。
  static Future<({String? text, Uint8List bytes, bool truncated})> readBytes(
    String path, {
    int cap = 64 * 1024,
    String channelName = defaultChannelName,
  }) async {
    final value = await MethodChannel(channelName).invokeMethod<Map>('readBytes', {
      'path': path,
      'cap': cap,
    });
    final encoded = value?['base64'] as String? ?? '';
    return (
      text: value?['text'] as String?,
      bytes: base64Decode(encoded),
      truncated: value?['truncated'] as bool? ?? false,
    );
  }
}
