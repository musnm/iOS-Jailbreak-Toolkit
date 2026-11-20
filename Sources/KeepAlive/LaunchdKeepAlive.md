# 越狱 launchd 保活（真常驻）

前面三种手段都只是「延缓挂起」。想要**真正常驻**，只有越狱 + launchd。

本机环境（实测）：iOS 16.x / iPhone15,3 / Dopamine 隐根，root shell 内入口固定为 `/var/jb`（UUID 会变，**不要硬编码真实路径**）。

## 一、为什么 launchd 能真常驻

iOS 的进程管理由 `launchd`（PID 1）负责。App 进程被系统挂起/杀死是因为它的 launchd job 没有 `KeepAlive` 属性。越狱后可以写自己的 plist，声明：

- `KeepAlive = true` —— 进程退出立刻重启
- `RunAtLoad = true` —— 开机自启
- `ThrottleInterval` —— 防止疯狂重启

## 二、目录位置

```
/var/jb/Library/LaunchDaemons/             ← 系统级（root 运行，开机自启）
/var/jb/var/mobile/Library/LaunchAgents/   ← 用户级（mobile 身份，登录后启动）
```

App 自身要有后台权限的话，优先考虑 **LaunchAgent**（mobile 身份，能访问 App 沙盒）；需要 root 才用 LaunchDaemon。

## 三、写一个 LaunchAgent

`/var/jb/var/mobile/Library/LaunchAgents/com.example.keepalive.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.example.keepalive</string>

    <key>ProgramArguments</key>
    <array>
        <string>/var/jb/usr/bin/sh</string>
        <string>/var/mobile/keepalive.sh</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <!-- 进程退出立刻重启 -->
    <key>KeepAlive</key>
    <true/>

    <!-- 两次启动至少间隔 10 秒，防止崩溃循环把 CPU 打满 -->
    <key>ThrottleInterval</key>
    <integer>10</integer>

    <key>StandardOutPath</key>
    <string>/var/mobile/keepalive.log</string>
    <key>StandardErrorPath</key>
    <string>/var/mobile/keepalive.log</string>

    <!-- 需要访问 App 沙盒时用这个（容器 UUID 会变，用通配） -->
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>/var/mobile</string>
    </dict>
</dict>
</plist>
```

## 四、加载与调试

```sh
# 加载（root shell 内）
launchctl load -w /var/jb/var/mobile/Library/LaunchAgents/com.example.keepalive.plist

# 查看状态
launchctl list | grep keepalive

# 卸载
launchctl unload -w /var/jb/var/mobile/Library/LaunchAgents/com.example.keepalive.plist

# 看日志
tail -f /var/mobile/keepalive.log
```

## 五、守护 App 进程的写法

launchd 守护的是「脚本」，脚本负责检查并拉起 App 主进程：

```sh
#!/bin/sh
# /var/mobile/keepalive.sh
APP_BIN="/var/containers/Bundle/Application/<UUID>/MyApp.app/MyApp"

while true; do
    if ! pgrep -f "MyApp.app/MyApp" > /dev/null 2>&1; then
        # 拉起 App（需要 App 支持从命令行启动，多数 App 需要配合 open 或 UIApplicationLaunchOptions）
        "$APP_BIN" > /dev/null 2>&1 &
    fi
    sleep 30
done
```

**注意**：`/var/containers/Bundle/Application/<UUID>` 里的 UUID 每次重装都会变，脚本里要动态查找：

```sh
APP_BIN=$(find /var/containers/Bundle/Application -maxdepth 2 -name "MyApp.app" -type d 2>/dev/null | head -1)/MyApp
```

## 六、红线

动手前确认三件事：

1. **删之前先看** —— `rm` 前先 `ls` 目标路径确认
2. **动系统先说明** —— 碰 `/System`、`/var/jb/boot`、`/dev/`、launchd 配置前先讲清后果
3. **不碰 basebin** —— `/var/jb/basebin`、`/var/jb/boot` 是越狱本体，删了会变砖

另外：`KeepAlive = true` 写错（比如指向不存在的二进制）会让 launchd 每 10 秒重启一次，手机发烫掉电。写完先 `launchctl list` 看状态，确认 `LastExitStatus` 是 0。

## 七、和前面三种手段的关系

| 场景 | 用哪个 |
|---|---|
| 上架 App Store | 静音音频（有音频语义才合法）/ BGTask |
| 自签 / TrollStore 自用 | 静音音频 + 定位，够了 |
| 越狱，要真常驻 | launchd，前面的都可以关掉 |

越狱设备上 launchd 方案本身不耗电（只是 `sleep 30` 轮询），比持续定位省得多。
