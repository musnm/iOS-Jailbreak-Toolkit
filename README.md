# iOS 高阶能力工具箱

iOS 没有 Android 那种前台服务，App 进后台后很快被挂起；而越狱 / 巨魔设备上还有一批普通 App 拿不到的能力。

这个仓库把两部分合成一套：

- **后台保活** —— 能合法延缓挂起的手段（未越狱也能用）
- **环境探测 + 系统 shell** —— 越狱 / 巨魔设备才能拿到的能力

全部是可直接复用的 Swift + Dart 代码，拖进工程即可。

---

## 手段对比

### 保活

> 先说清楚：除了越狱 launchd，其余手段都只是「延缓」，不是「常驻」。内存紧张时系统照样回收。

| 手段 | 需要 | 效果 | 耗电 | 上架风险 | 适用 |
|---|---|---|---|---|---|
| **静音音频** | `UIBackgroundModes: audio` | 好，进程基本不被冻结 | 低 | 中（滥用会被拒） | 有音频/后台任务语义的 App |
| **持续定位** | `UIBackgroundModes: location` + 始终授权 | 好 | **高** | **高**（非导航类明确违规） | 导航、运动类 |
| **BGTaskScheduler** | `BGTaskSchedulerPermittedIdentifiers` | 差，系统决定何时跑 | 无 | 无 | 定期同步、清理 |
| **越狱 launchd** | 已越狱 | **真常驻** | 无 | 不上架 | 自用 |

### 越狱能力

| 能力 | 需要 | 说明 |
|---|---|---|
| **环境探测** | 否（部分项需越狱才为真） | 识别越狱形态、巨魔、注入库、沙箱边界 |
| **系统 shell** | 是 | 执行任意命令、列目录、读任意文件 |

---

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
  Info.plist.example                 需要的 plist 键（完整 XML）
  integration.md                     三种接入方式 + UI 建议 + 常见问题
```

所有 Swift 文件都可以直接拖进 Xcode 工程；非 Flutter 项目不需要 `*Channel.swift`（那是通道桥）。

---

## 最快接入（Flutter 项目）

### 1. 复制文件

```sh
cp Sources/KeepAlive/*.swift  YourApp/ios/Runner/
cp flutter/*.dart             YourApp/lib/
```

**传统 pbxproj 工程注意**：新增 `.swift` 文件必须同时注册进 PBXBuildFile / PBXFileReference / group / Sources，光复制文件不会被编译。
最省事的做法是**把类的代码追加到已有的 `AppDelegate.swift` 末尾**，这样不用改工程文件。

### 2. 注册通道

`AppDelegate.swift` 的 `application(_:didFinishLaunchingWithOptions:)` 里，`GeneratedPluginRegistrant.register(with:)` 之后：

```swift
if let r = self.registrar(forPlugin: "KeepAliveChannel") {
    KeepAliveChannel.register(with: r)
}
if let r = self.registrar(forPlugin: "AdvancedEnvironmentChannel") {
    AdvancedEnvironmentChannel.register(with: r)
}
if let r = self.registrar(forPlugin: "SystemShellChannel") {
    SystemShellChannel.register(with: r)
}
```

Flutter 3.x 的 `FlutterAppDelegate` 提供了 `registrar(forPlugin:)`；新版 Flutter（`FlutterImplicitEngineDelegate`）改在 `didInitializeImplicitFlutterEngine` 里注册。

### 3. 改 Info.plist

见 `docs/Info.plist.example`，按需取用，**不要整段替换**原有 Info.plist。

### 4. 调用

见下面「用法」。

---

## 用法

### 后台保活

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
if (result.ok) print(result.stdout);

// 或直接读文件
final hosts = await SystemShell.readBytes('/etc/hosts');
print(hosts.text);
```

### 原生 Swift 项目

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

// 系统 shell（仅越狱/巨魔可用）
let result = SystemShellChannel.run(
    command: "ls -la /var/mobile", cwd: nil, env: nil,
    timeoutMs: 20000, maxBytes: 256 * 1024)
```

### Objective-C 项目

```objc
#import "YourApp-Swift.h"

[[BackgroundKeepAlive shared] setAudioKeepAlive:YES];
NSDictionary *s = [[BackgroundKeepAlive shared] status];
AdvancedEnvironment *env = [AdvancedEnvironmentDetector detect];
if (env.isJailbroken) NSLog(@"越狱: %@", env.jailbreakType);
```

---

## 探测项清单

`AdvancedEnvironmentDetector` 覆盖的检查：

| 检查 | 字段 | 说明 |
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

结果默认缓存（`NSLock` 保护），需要实时结果时传 `cached: false`。

---

## 常见问题

**Q: 开了音频保活，但后台还是被杀**

检查三处：
1. `UIBackgroundModes` 里有 `audio` 吗
2. `AVAudioSession.setCategory(.playback)` 成功了吗（catch 里有 NSLog）
3. App 是否被用户手动上滑划掉 —— 划掉后系统不再恢复，任何保活手段都无效

**Q: 定位开了，状态显示 location=true 但没效果**

`authorizationStatus` 必须是 `authorizedAlways`。`whenInUse` 在后台不生效。iOS 13+ 的「始终允许」需要用户二次确认，`requestAlwaysAuthorization()` 之后系统可能先给 `whenInUse`，要监听 `locationManagerDidChangeAuthorization` 再启动。

**Q: 上架审核被拒**

静音音频保活如果 App 没有音频语义，会被判滥用 `audio` background mode。定位保活非导航类同样违规。上架版建议只留 BGTask，或者做成「可关闭的高级设置」。

**Q: 耗电太快**

定位是主要耗电来源。可以只留音频通道：`setLocation(false)`。或者用越狱 launchd 方案，几乎不耗电。

**Q: shell 一直返回 `no usable shell`**

说明当前环境不是越狱状态，或者越狱根不在默认候选路径里。在 `SystemShellChannel.swift` 的 `shellCandidates` 数组末尾追加你的路径。

**Q: 探测结果全是 false，但设备确实越狱了**

先确认 `LSApplicationQueriesSchemes` 加了（否则 `canOpenScheme` 恒为 false），再确认 App 是从 TrollStore 装的还是普通签名 —— 普通签名的 App 即使设备越狱，沙箱仍然有效。

更多见 `docs/integration.md`。

---

## 安全与合规

- **只用在自己和你拥有/被授权的设备上。** 越狱环境下的命令执行能力等价于设备完全控制权。
- 未越狱设备上 `SystemShell` 全部返回 `no usable shell`，`AdvancedEnvironment` 的越狱相关项为 `false`。
- 静音音频保活可能被 App Store 审核判为滥用 `audio` 后台模式；持续定位在非导航类 App 上属于明确违规。**自己签名安装（TrollStore / 自签）没有这个限制。**
- 探测结果不含任何坐标、设备标识或用户数据，只有环境布尔值与路径。

---

## 平台支持

| 平台 | 保活 | 环境探测 | 系统 shell |
|---|---|---|---|
| iOS 越狱（rootless / roothide / rootful） | ✅ | ✅ | ✅ |
| iOS 巨魔（TrollStore） | ✅ | ✅ | ✅ |
| iOS 未越狱 / 自签 | ✅ | 部分项固定为 false | ❌ |
| iOS 模拟器 | ✅ | 可跑，无实际意义 | ❌ |

---

## 许可

MIT。后台保活的原始代码取自 [dsh-go](https://github.com/ccch1mneyyy/dsh-Go) 社区 fork（AGPL-3.0），
改写与补充部分按 MIT 发布；环境探测与系统 shell 部分为本仓库原创。

详见 [LICENSE](LICENSE)。
