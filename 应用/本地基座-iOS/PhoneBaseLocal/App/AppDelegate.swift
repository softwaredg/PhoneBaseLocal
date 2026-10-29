import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private let runtime = BaseRuntime.shared

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = RootViewController(runtime: runtime)
        window.makeKeyAndVisible()
        self.window = window
        LocalNetworkPermission.shared.requestIfNeeded()
        runtime.start()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        runtime.setStreamingActive(false)
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        runtime.setStreamingActive(true)
    }
}
