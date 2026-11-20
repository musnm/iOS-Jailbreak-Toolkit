//
//  KeepAliveTask.swift
//  BGTaskScheduler 封装：定期刷新类任务（同步、清理、预取）。
//
//  这是唯一「零风险」的保活手段 —— 系统允许、上架无忧，但触发时机由系统决定，
//  不能指望它准点。适合做「App 不在前台时偶尔跑一下」，不适合做实时任务。
//
//  用法：
//      KeepAliveTask.register(id: "com.example.app.refresh") { completion in
//          // 后台跑活，跑完必须调 completion
//          completion(true)
//      }
//      KeepAliveTask.schedule(id: "com.example.app.refresh", after: 15 * 60)
//
//  Info.plist 必须加（否则 register 直接失败）：
//      BGTaskSchedulerPermittedIdentifiers = ["com.example.app.refresh"]
//
//  注意：identifier 必须与 Info.plist 里的字符串完全一致，包括大小写。
//  另外 iOS 会按 App 使用频率决定是否真的调度 —— 用得少就调得少。
//
import BackgroundTasks
import Foundation

public enum KeepAliveTask {

    /// 注册一个后台刷新任务。必须在 didFinishLaunchingWithOptions 返回前调用。
    ///
    /// - Parameters:
    ///   - id: 必须与 Info.plist 的 BGTaskSchedulerPermittedIdentifiers 一致
    ///   - work: 后台执行的闭包；内部必须调用 completion(true) 表示成功
    /// - Returns: 是否提交了注册（true 表示 identifier 合法）
    @discardableResult
    public static func register(id: String,
                                work: @escaping (@escaping (Bool) -> Void) -> Void) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
            // 任务开始后重新排下一次，否则只跑一次就没了
            schedule(id: id, after: 15 * 60)
            task.expirationHandler = {
                // 系统要收回时间了，这里做收尾（保存进度、释放锁）
            }
            work { success in
                task.setTaskCompleted(success: success)
            }
        }
        return true
    }

    /// 排一个后台刷新任务。
    ///
    /// - Parameter after: 最早多久之后执行（秒）。系统可能延后，不会提前。
    public static func schedule(id: String, after: TimeInterval) {
        let request = BGAppRefreshTaskRequest(identifier: id)
        request.earliestBeginDate = Date(timeIntervalSinceNow: after)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NSLog("[KeepAlive] BGTask 排期失败 \(id): \(error)")
        }
    }

    /// 取消所有已排期的任务。
    public static func cancelAll() {
        BGTaskScheduler.shared.cancelAllTaskRequests()
    }
}
