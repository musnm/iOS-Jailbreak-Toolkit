# 接入说明

三种接入方式，按你的项目类型选。

## 一、Flutter 项目（推荐）

### 1. 复制源码

```sh
# Swift 进 ios/Runner/
cp Sources/KeepAlive/BackgroundKeepAlive.swift         YourApp/ios/Runner/
cp Sources/KeepAlive/KeepAliveChannel.swift            YourApp/ios/Runner/
cp Sources/KeepAlive/AdvancedEnvironmentDetector.swift YourApp/ios/Runner/
cp Sources/KeepAlive/AdvancedEnvironmentChannel.swift  YourApp/ios/Runner/
cp Sources/KeepAlive/SystemShellChannel.swift          YourApp/ios/Runner/
# 需要定期后台唤醒再加这个
cp Sources/KeepAlive/KeepAliveTask.swift               YourApp/ios/Runner/

# Dart 进 lib/
cp flutter/keep_alive.dart          YourApp/lib/
cp flutter/environment_probe.dart   YourApp/lib/
```

### 2. 加入 Xcode 工程

有两个办法：

**A. 用 Xcode 界面**
`Runner` target → Build Phases → Compile Sources → 点 `+` → 选中新增的 `.swift` 文件。

**B. 干脆不新增文件**
如果不想动 pbxproj，把内容直接粘贴到已有的 `AppDelegate.swift` 末尾。Swift 允许一个文件里放多个类，这样零配置。

### 3. 注册通道

```swift
// AppDelegate.swift 的 didFinishLaunchingWithOptions 里，GeneratedPluginRegistrant.register 之后
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

### 4. 加 plist 键

按 `docs/Info.plist.example` 合并。

## 二、原生 Swift 项目

只需要 Swift 部分，跳过 `flutter/` 目录。

```swift
// 保活
BackgroundKeepAlive.shared.setAudioKeepAlive(true)
BackgroundKeepAlive.shared.setLocationKeepAlive(true)
let status = BackgroundKeepAlive.shared.status()

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
print(result["stdout"] ?? "")
```

> 原生项目里不需要 `*Channel.swift`，那是 Flutter 专用的桥。但 `SystemShellChannel` 里的 `run` / `listDirectory` / `readBytes` 都是不带状态的 `static`，可以直接复用；不想引入 Flutter 依赖的话，把这三个方法抠到自己的类里即可。

## 三、Objective-C 项目

Swift 类加 `@objc` 后可直接调用。需要先建一个 Swift 文件让 Xcode 生成 `YourApp-Swift.h`。

```objc
#import "YourApp-Swift.h"

[BackgroundKeepAlive shared];
[[BackgroundKeepAlive shared] setAudioKeepAlive:YES];
AdvancedEnvironment *env = [AdvancedEnvironmentDetector detect];
if (env.isJailbroken) {
    NSLog(@"越狱: %@", env.jailbreakType);
}
```

## 常见问题

### 编译报 `Undefined symbol: _dyld_image_count`

加 `import Darwin`，或者确认链接了 `libSystem`（默认就有）。

### 编译报 `SecTaskCreateFromSelf` 找不到

`Security.framework` 默认链接；如果用了 SPM 分包，需要在 target 的 Link Binary With Libraries 里加上 `Security.framework`。

### shell 一直返回 `no usable shell`

说明当前环境不是越狱状态，或者越狱根不在默认候选路径里。可以自己加路径：

```swift
// SystemShellChannel.swift 的 shellCandidates 数组末尾追加
"/你的/越狱根/usr/bin/sh",
```

### 探测结果全是 false，但设备确实越狱了

先确认 `LSApplicationQueriesSchemes` 加了（否则 `canOpenScheme` 恒为 false），再确认 App 是从 TrollStore 装的还是普通签名 —— 普通签名的 App 即使设备越狱，沙箱仍然有效，读系统路径会被拒。

### 音频保活开了但后台还是被挂

检查：
1. `UIBackgroundModes` 里有 `audio`
2. `AVAudioSession` 的 category 是 `.playback` 不是 `.ambient`
3. 真机上测，模拟器不模拟后台挂起

### 定位保活开了没反应

`authorizationStatus` 必须是 `authorizedAlways`。如果是 `authorizedWhenInUse`，需要引导用户去系统设置改成「始终」。

### 探测很慢

`detect()` 默认走缓存，第一次会做 fork + spawn 验证，大约几十毫秒。不要在主线程同步调；通道实现里已经放到后台队列了，直接用 `probe()` 即可。
