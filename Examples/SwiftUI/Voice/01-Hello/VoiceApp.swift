// Copyright PolyAI Limited

import SwiftUI
import PolyMessaging

@main
struct VoiceApp: App {
    init() {
        PolyMessaging.initialize(.init(
            apiKey: "YOUR_CONNECTOR_TOKEN",       // Agent Studio → Connector Settings
            webrtcToken: "YOUR_WEB_CALLING_TOKEN" // same place — needed only for PolyVoice.call()
        ))
    }
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
