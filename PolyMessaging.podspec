Pod::Spec.new do |s|
  s.name             = 'PolyMessaging'
  # Keep in sync with Sources/PolyMessaging/Public/Version.swift and CHANGELOG.md.
  s.version          = '0.11.0'
  s.summary          = 'Fully managed chat over the PolyAI Messaging API for iOS.'
  s.description      = <<-DESC
    PolyMessaging is a dependency-free Swift SDK for the PolyAI Messaging API:
    token auth, session create/resume, WebSocket lifecycle and reconnection with
    cursor-based replay, streaming chunk reassembly, optimistic send with delivery
    tracking, and live-agent handoff — exposed through a bindable ChatSession for
    SwiftUI and UIKit.
  DESC
  s.homepage         = 'https://github.com/polyai/ios-sdk'
  s.license          = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author           = { 'PolyAI Limited' => 'messaging-pod@poly-ai.com' }
  s.source           = { :git => 'https://github.com/polyai/ios-sdk.git', :tag => "v#{s.version}" }

  s.swift_version            = '5.9'
  s.ios.deployment_target    = '15.0'
  s.osx.deployment_target    = '12.0'

  # Source-only, dependency-free. All imported frameworks (Foundation, Security,
  # CryptoKit, Combine, Network, UIKit) are system frameworks auto-linked by Swift.
  s.source_files     = 'Sources/PolyMessaging/**/*.swift'
end
