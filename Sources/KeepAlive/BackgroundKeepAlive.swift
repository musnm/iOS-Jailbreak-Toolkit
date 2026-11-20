//
//  BackgroundKeepAlive.swift
//  iOS 后台保活：静音音频 + 持续定位
//
//  用法：
//    BackgroundKeepAlive.shared.setAudioKeepAlive(true)
//    BackgroundKeepAlive.shared.setLocationKeepAlive(true)
//    BackgroundKeepAlive.shared.status()   // ["audio": Bool, "location": Bool, ...]
//
//  需要的 Info.plist：
//    UIBackgroundModes = [audio, location]
//    NSLocationAlwaysAndWhenInUseUsageDescription = "..."
//
//  说明：
//    这是「延缓挂起」，不是常驻。内存压力大时系统仍会回收进程。
//    真常驻只能越狱用 launchd（见 LaunchdKeepAlive.md）。
//
import AVFoundation
import CoreLocation

@objc(BackgroundKeepAlive)
public final class BackgroundKeepAlive: NSObject {

    public static let shared = BackgroundKeepAlive()

    private var player: AVAudioPlayer?
    private var locationManager: CLLocationManager?
    private var audioActive = false
    private var locationActive = false

    private override init() { super.init() }

    // MARK: - 音频通道

    /// 生成一段 1 秒的极低幅度正弦波（约 -62 dBFS），用于循环播放。
    ///
    /// 为什么不用全零 PCM：部分 iOS 版本会把全零数据识别成静音流并降级优先级，
    /// 反而失去保活效果。留一点不可闻的波形能稳定通过系统判定。
    private func makeNearSilentWAV(seconds: Double = 1.0, sampleRate: Double = 8000) -> Data? {
        let frames = Int(seconds * sampleRate)
        let amplitude: Int16 = 6           // ≈ -62 dBFS，人耳不可闻
        let freq = 220.0
        var pcm = Data(capacity: frames * 2)
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            let v = Int16(Double(amplitude) * sin(2.0 * .pi * freq * t))
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var wav = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append("RIFF".data(using: .ascii)!)
        le32(UInt32(36 + pcm.count))
        wav.append("WAVEfmt ".data(using: .ascii)!)
        le32(16); le16(1); le16(1)             // PCM, mono
        le32(UInt32(sampleRate)); le32(UInt32(sampleRate * 2))
        le16(2); le16(16)
        wav.append("data".data(using: .ascii)!)
        le32(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }

    /// 开关静音音频保活。返回操作后的实际状态。
    @discardableResult
    public func setAudioKeepAlive(_ on: Bool) -> Bool {
        if on == audioActive { return audioActive }
        guard on else {
            player?.stop(); player = nil
            audioActive = false
            try? AVAudioSession.sharedInstance().setActive(false,
                options: [.notifyOthersOnDeactivation])
            return false
        }
        do {
            let session = AVAudioSession.sharedInstance()
            // .playback + .mixWithOthers：
            //   - .playback 允许后台播放（.ambient 不行）
            //   - .mixWithOthers 不打断别的 App 的音乐，也不被电话打断后彻底停掉
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            guard let wav = makeNearSilentWAV() else { return false }
            let p = try AVAudioPlayer(data: wav)
            p.numberOfLoops = -1          // 无限循环
            p.volume = 0.0                // 输出音量归零，双保险
            p.prepareToPlay()
            p.play()
            player = p
            audioActive = true
            return true
        } catch {
            NSLog("[KeepAlive] 音频保活启动失败: \(error)")
            audioActive = false
            return false
        }
    }

    // MARK: - 定位通道

    /// 开关定位保活。返回操作后的实际状态。
    ///
    /// 首次调用会弹权限请求。用户只给「使用期间」时后台无效，
    /// 需要在设置里改成「始终允许」，或等 authorizationStatus 变化后重新调用。
    @discardableResult
    public func setLocationKeepAlive(_ on: Bool) -> Bool {
        if on == locationActive { return locationActive }
        guard on else {
            locationManager?.stopUpdatingLocation()
            locationManager = nil
            locationActive = false
            return false
        }
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyThreeKilometers   // 最省电
        m.distanceFilter = 3000                                   // 3km 才回调一次
        m.pausesLocationUpdatesAutomatically = false              // 别让系统自动停
        m.allowsBackgroundLocationUpdates = true                  // 需要 location background mode
        let status = m.authorizationStatus
        if status == .notDetermined {
            m.requestAlwaysAuthorization()
        } else if status == .authorizedWhenInUse || status == .authorizedAlways {
            m.startUpdatingLocation()
            locationActive = true
        } else {
            return false
        }
        locationManager = m
        return true
    }

    // MARK: - 状态查询

    public func status() -> [String: Any] {
        let s = CLLocationManager().authorizationStatus
        let locAuth: String
        switch s {
        case .authorizedAlways: locAuth = "always"
        case .authorizedWhenInUse: locAuth = "whenInUse"
        case .denied: locAuth = "denied"
        case .restricted: locAuth = "restricted"
        case .notDetermined: locAuth = "notDetermined"
        @unknown default: locAuth = "unknown"
        }
        return [
            "audio": audioActive,
            "location": locationActive,
            "locationAuthorization": locAuth,
        ]
    }

    /// 全部关掉（App 即将退出 / 用户手动关闭时调用）。
    public func stopAll() {
        _ = setAudioKeepAlive(false)
        _ = setLocationKeepAlive(false)
    }
}

extension BackgroundKeepAlive: CLLocationManagerDelegate {
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // 只要回调就算续命成功，不消费坐标
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NSLog("[KeepAlive] 定位回调错误: \(error.localizedDescription)")
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways
            || manager.authorizationStatus == .authorizedWhenInUse {
            manager.startUpdatingLocation()
            locationActive = true
        }
    }
}
