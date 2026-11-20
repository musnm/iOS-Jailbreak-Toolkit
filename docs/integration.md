# 接入步骤

覆盖三种项目类型。先看你的项目属于哪种，只读对应那一节。

---

## 一、Flutter 项目

### 1. 放 Swift 文件

复制到 `ios/Runner/`：

**保活（按需）**
- `BackgroundKeepAlive.swift` —— 必需
- `KeepAliveChannel.swift` —— 需要 Dart 控制才加
- `KeepAliveTask.swift` —— 需要 BGTask 才加

**探测（按需）**
- `AdvancedEnvironmentDetector.swift` —— 必需
- `AdvancedEnvironmentChannel.swift` —— 需要 Dart 读探测结果才加
- `SystemShellChannel.swift` —— 需要执行命令才加

**传统 pbxproj 工程注意**：新增 `.swift` 文件必须同时注册进 PBXBuildFile / PBXFileReference / group / Sources，光复制文件不会被编译。

最省事的做法是**直接把类的代码追加到已有的 `AppDelegate.swift` 末尾**，import 放在文件顶部。这样不用改工程文件。

### 2. 注册通道

`AppDelegate.swift` 的 `application(_:didFinishLaunchingWithOptions:)` 里，`GeneratedPluginRegistrant.register(with:)` 之后加：

```swift
if let registrar = self.registrar(forPlugin: "KeepAliveChannel") {
    KeepAliveChannel.register(with: registrar)
}
if let registrar = self.registrar(forPlugin: "AdvancedEnvironmentChannel") {
    AdvancedEnvironmentChannel.register(with: registrar)
}
if let registrar = self.registrar(forPlugin: "SystemShellChannel") {
    SystemShellChannel.register(with: registrar)
}
```

Flutter 3.x 的 `FlutterAppDelegate` 提供了 `registrar(forPlugin:)`；如果用的是新版 Flutter（`FlutterImplicitEngineDelegate`），改在 `didInitializeImplicitFlutterEngine` 里注册。

### 3. 改 Info.plist

见 `docs/Info.plist.example`。

### 4. 复制 Dart 文件

```sh
cp flutter/keep_alive.dart         lib/runtime/keep_alive.dart
cp flutter/environment_probe.dart  lib/runtime/environment_probe.dart
```

### 5. 调用

**保活**

```dart
const ka = BackgroundKeepAlive();

// 读状态
final s = await ka.status();
print('音频: ${s.audio}  定位: ${s.location}  授权: ${s.locationAuthorization}');

// 开音频
final ok = await ka.setAudio(true);

// 开定位（首次会弹权限）
final okLoc = await ka.setLocation(true);
if (!okLoc) {
  // 用户可能只给了「使用期间」，需要引导去设置改「始终允许」
}

// 全关
await ka.stopAll();
```

**UI 建议** —— 放在「设置 → 后台」页，带耗电提示：

```
后台保活
  [开关] 静音音频保活   循环播放不可闻音频，进后台后不被立刻挂起
  [开关] 定位保活       持续定位维持后台唤醒，精度已降到最低
  ⚠ 这不是常驻：内存紧张时系统仍会回收。耗电会增加，按需开启。
```

App 回到前台时刷新状态（用户可能去设置里改过权限）：

```dart
AppLifecycleListener(onResume: () => _refreshKeepAlive());
```

**探测**

```dart
final env = await AdvancedEnvironment.probe();
print(env.headline);                 // "已越狱（rootless） · 巨魔 · 可执行系统命令"
print(env.injectionLibraries);       // 注入的 dylib
print(env.sandboxDeniedPaths);       // 沙箱拒绝的路径
```

**系统 shell**

```dart
final r = await SystemShell.run('ls -la /var/mobile');
if (r.ok) print(r.stdout);
```

---

## 二、原生 Swift 项目

只需要 Swift 部分，跳过 `flutter/` 目录。

### 1. 加文件

把 `Sources/KeepAlive/` 里需要的 `.swift` 拖进 Xcode 工程（勾选 target）。

**不需要** `*Channel.swift`，那是 Flutter 通道桥。

### 2. 改 Info.plist

### 3. 调用

```swift
// 保活
BackgroundKeepAlive.shared.setAudioKeepAlive(true)
BackgroundKeepAlive.shared.setLocationKeepAlive(true)
print(BackgroundKeepAlive.shared.status())

// 探测
let env = AdvancedEnvironmentDetector.detect()
if env.isJailbroken {
    print("越狱形态: \(env.jailbreakType)")
    print("注入库: \(env.injectionLibraries)")
}
print(env.summaryLines.joined(separator: "\n"))

// 系统 shell
let result = SystemShellChannel.run(
    command: "ls -la /var/mobile", cwd: nil, env: nil,
    timeoutMs: 20000, maxBytes: 256 * 1024)
```

> `SystemShellChannel` 虽然带 Flutter 依赖，但 `run` / `listDirectory` / `readBytes` 都是无状态的 `static` 方法。不想引入 Flutter 的话，把这三个方法抠到你自己的类里即可。

---

## 三、Objective-C 项目

Swift 类可以直接从 OC 调用（`@objc` 已标）：

```objc
#import "MyApp-Swift.h"

[[BackgroundKeepAlive shared] setAudioKeepAlive:YES];
NSDictionary *s = [[BackgroundKeepAlive shared] status];

AdvancedEnvironment *env = [AdvancedEnvironmentDetector detect];
if (env.isJailbroken) NSLog(@"越狱: %@", env.jailbreakType);
```

工程需要配置 `SWIFT_OBJC_INTERFACE_HEADER_NAME`（Xcode 默认已生成 `项目名-Swift.h`）。

---

## 常见问题

**Q: 开了音频保活，但后台还是被杀**

A: 检查三处：
1. `UIBackgroundModes` 里有 `audio` 吗
2. `AVAudioSession.setCategory(.playback)` 成功了吗（catch 里有 NSLog）
3. App 是否被用户手动上滑划掉 —— 划掉后系统不再恢复，任何保活手段都无效

**Q: 定位开了，状态显示 location=true 但没效果**

A: `authorizationStatus` 必须是 `authorizedAlways`。`whenInUse` 在后台不生效。iOS 13+ 的「始终允许」需要用户二次确认，`requestAlwaysAuthorization()` 之后系统可能先给 `whenInUse`，要监听 `locationManagerDidChangeAuthorization` 再启动。

**Q: 上架审核被拒**

A: 静音音频保活如果 App 没有音频语义，会被判滥用 `audio` background mode。定位保活非导航类同样违规。上架版建议只留 BGTask，或者做成「可关闭的高级设置」。

**Q: 耗电太快**

A: 定位是主要耗电来源。可以只留音频通道：`setLocation(false)`。或者用越狱 launchd 方案，几乎不耗电。

**Q: 编译报 `Undefined symbol: _dyld_image_count`**

A: 加 `import Darwin`，或确认链接了 `libSystem`（默认就有）。

**Q: 编译报 `SecTaskCreateFromSelf` 找不到**

A: `Security.framework` 默认链接；如果用了 SPM 分包，需要在 target 的 Link Binary With Libraries 里加上 `Security.framework`。

**Q: shell 一直返回 `no usable shell`**

A: 说明当前环境不是越狱状态，或者越狱根不在默认候选路径里。在 `SystemShellChannel.swift` 的 `shellCandidates` 数组末尾追加你的路径。

**Q: 探测结果全是 false，但设备确实越狱了**

A: 先确认 `LSApplicationQueriesSchemes` 加了（否则 `canOpenScheme` 恒为 false），再确认 App 是从 TrollStore 装的还是普通签名 —— 普通签名的 App 即使设备越狱，沙箱仍然有效。

**Q: 探测很慢**

A: `detect()` 默认走缓存，第一次会做 fork + spawn 验证，大约几十毫秒。不要在主线程同步调；通道实现里已经放到后台队列，直接用 `probe()` 即可。
