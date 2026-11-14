import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // 纯代码启动（无 Storyboard），iPadOS 15 全尺寸窗口
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = PetViewController()
        w.makeKeyAndVisible()
        window = w
        application.isIdleTimerDisabled = true   // 宠物陪伴时不锁屏
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        (window?.rootViewController as? PetViewController)?.scene?.appWillResign()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        (window?.rootViewController as? PetViewController)?.scene?.appDidBecomeActive()
    }
}