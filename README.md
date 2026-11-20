# iOS 高阶能力工具箱

把 iOS 上**只有越狱 / 巨魔设备才能拿到**的能力，以及**未越狱也能用的保活手段**，整理成可以直接复用的 Swift + Dart 代码。

> 全部只读探测 + 显式放开的能力调用。代码本身不做任何隐藏行为，是否使用、用在哪，由你决定。

## 能力一览

| 模块 | 需要越狱 | 说明 |
|---|---|---|
| **后台保活** | 否 | 静音音频 + 持续定位，双保险延缓系统挂起 |
| **BGTaskScheduler** | 否 | 定期后台唤醒（系统决定时机） |
| **越狱 launchd** | 是 | 真常驻，进程不会被系统回收 |
| **环境探测** | 否（部分项需越狱才为真） | 识别越狱形态、巨魔、注入库、沙箱边界 |
| **系统 shell** | 是 | 执行任意命令、列目录、读任意文件 |

## 目录结构

```
Sources/KeepAlive/
  BackgroundKeepAlive.swift          静音音频 + 定位 + 状态查询
  KeepAliveChannel.swift             Flutter 通道 dshgo/keepalive
  KeepAliveTask.swift                BGTaskScheduler 封装
  LaunchdKeepAlive.md                越狱 launchd 真常驻方案
  AdvancedEnvironmentDetector.swift  越狱/巨魔/注入/沙箱探测主体
  AdvancedEnvironmentChannel.swift   Flutter 通道 dshgo/advanced_env
  SystemShellChannel.swift           命令执行 / 列目录 / 读文件
flutter/
  keep_alive.dart                    保活的 Dart 封装
  environment_probe.dart             探测与 shell 的 Dart 封装
docs/
  Info.plist.example                 需要的 plist 键
  integration.md                     三种接入方式
```

## 快速接入（Flutter）

### 1. 复制文件

```sh
cp Sources/KeepAlive/*.swift  YourApp/ios/Runner/
cp flutter/*.dart             YourApp/lib/
```

用传统 pbxproj 时，新增的 `.swift` 必须加进 **PBXBuildFile / PBXFileReference / group / Sources**，否则不会被编译。
最省事的做法是把需要的类直接追加到已有的 `AppDelegate.swift` 末尾。

### 2. 注册通道

在 `AppDelegate.swift` 的 `didFinishLaunchingWithOptions` 里：

```swift
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let registrar = self.registrar(forPlugin: "KeepAliveChannel") {
      KeepAliveChannel.register(with: registrar)
    }
    if let registrar = self.registrar(forPlugin: "AdvancedEnvironmentChannel") {
      AdvancedEnvironmentChannel.register(with: registrar)
    }
    if let registrar = self.registrar(forPlugin: "SystemShellChannel") {
      SystemShellChannel.register(with: registrar)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
```

### 3. 加 Info.plist 键

见 `docs/Info.plist.example`，关键几项：

```xml
<key>UIBackgroundModes</key>
<array><string>audio</string><string>location</string></array>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>后台维持引擎运行时需要</string>
<key>LSApplicationQueriesSchemes</key>
<array>
  <string>trollstore</string>
  <string>sileo</string>
  <string>cydia</string>
  <string>zbra</string>
  <string>apple-magnifier</string>
</array>
```

## 用法

### 后台保活

```dart
final keepAlive = BackgroundKeepAlive();
await keepAlive.setAudio(true);
await keepAlive.setLocation(true);
final status = await keepAlive.status();
// audio: true, location: true, locationAuthorization: "always"
```

### 环境探测

```dart
final env = await AdvancedEnvironment.probe();
if (env.isJailbroken) {
  print('越狱形态: ${env.jailbreakType}');   // rootless / roothide / rootful
}
print(env.headline);                          // "已越狱（rootless） · 巨魔 · 可执行系统命令"
print(env.injectionLibraries);                // 注入的 dylib 路径
print(env.sandboxDeniedPaths);                // 沙箱拒绝读的系统路径
```

### 系统 shell

```dart
final result = await SystemShell.run('ls -la /var/mobile');
if (result.ok) {
  print(result.stdout);
}
// 或直接读文件
final hosts = await SystemShell.readBytes('/etc/hosts');
print(hosts.text);
```

## 探测项清单

`AdvancedEnvironmentDetector` 覆盖的检查：

| 检查 | 方法 | 说明 |
|---|---|---|
| 越狱形态 | `jailbreakType` | roothide → rootless → rootful 优先级判定 |
| 巨魔安装 | `hasTrollStore` | 标志目录 + 偏好 plist + scheme |
| 巨魔签名 | `trollStoreSigned` | `platform-application` entitlement |
| 包管理器 | `hasCydia` / `hasSileo` / `hasZebra` | 路径 + scheme |
| 注入库 | `injectionLibraries` | 静态路径 + dyld 实际加载镜像 |
| 环境变量 | `environmentHits` | `JBROOT` / `_JBROOT` / `DYLD_INSERT_LIBRARIES` |
| 系统文件可读 | `canReadSystemFiles` | `/etc/hosts` 等 6 个路径 |
| 系统目录可写 | `canWriteSystemArea` | `/var/mobile` |
| 沙箱边界 | `sandboxDeniedPaths` | 被拒的路径列表 |
| 能否 fork | `canFork` | 真 fork 一个进程再退出 |
| shell 可执行 | `canSpawnShell` | 真跑 `echo` 验证 |

## 安全与合规

- **只用在自己和你拥有/被授权的设备上。** 越狱环境下的命令执行能力等价于设备完全控制权。
- 未越狱设备上 `SystemShell` 全部返回 `no usable shell` 错误，`AdvancedEnvironment` 的越狱相关项为 `false`。
- 静音音频保活可能被 App Store 审核判为滥用 `audio` 后台模式，上架前请确认你的 App 有真实的音频语义。
- 持续定位在非导航类 App 上属于明确违规。**自己签名安装（TrollStore / 自签）没有这个限制。**
- 探测结果里**不包含任何坐标、设备标识或用户数据**，仅含环境布尔值与路径。

## 平台支持

| 平台 | 保活 | 环境探测 | 系统 shell |
|---|---|---|---|
| iOS 越狱（rootless/roothide/rootful） | ✅ | ✅ | ✅ |
| iOS 巨魔（TrollStore） | ✅ | ✅ | ✅ |
| iOS 未越狱 / 自签 | ✅ | 部分项固定为 false | ❌ |
| iOS 模拟器 | ✅ | 可跑，无实际意义 | ❌ |

## 许可证

MIT
