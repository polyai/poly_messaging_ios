// Copyright PolyAI Limited

import UIKit
import PolyMessaging

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        PolyMessaging.initialize(.init(
            apiKey: "YOUR_CONNECTOR_TOKEN",       // Agent Studio → Connector Settings
            webrtcToken: "YOUR_WEB_CALLING_TOKEN" // same place — needed only for PolyVoice.call()
        ))
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}
