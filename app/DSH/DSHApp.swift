//  DSHApp.swift - DeepSeek Harness iOS 壳
//  三 Tab：对话 / 环境 / 设置。
//  「对话」Tab 加载本机 dsh web 起的 HTTP 服务（127.0.0.1:43129），
//  也就是 DSH 原版前端；因此 UI 与桌面版完全一致。
//
//  为什么用 WKWebView 而不是自绘聊天界面：
//    dsh-web-frontend（5.44MB）是完整的 React 前端，自带会话列表、
//    消息流、工具调用卡片、diff 视图、文件预览。自绘等于重写一遍，
//    而且永远追不上上游。WKWebView 是 WKWebView，不是 Chromium，
//    Apple 不禁止，Safari 内核就是它。
import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = RootTabBarController()
        w.makeKeyAndVisible()
        self.window = w
        return true
    }
}

final class RootTabBarController: UITabBarController {
    override func viewDidLoad() {
        super.viewDidLoad()
        tabBar.tintColor = UIColor(red: 0.31, green: 0.44, blue: 0.96, alpha: 1.0)

        let chat = ChatViewController()
        let env  = EnvironmentViewController()
        let set  = SettingsViewController()

        chat.tabBarItem = UITabBarItem(title: "对话", image: UIImage(systemName: "bubble.left.and.bubble.right"), tag: 0)
        env.tabBarItem  = UITabBarItem(title: "环境", image: UIImage(systemName: "shippingbox"), tag: 1)
        set.tabBarItem  = UITabBarItem(title: "设置", image: UIImage(systemName: "gearshape"), tag: 2)

        viewControllers = [
            UINavigationController(rootViewController: chat),
            UINavigationController(rootViewController: env),
            UINavigationController(rootViewController: set),
        ]
    }
}