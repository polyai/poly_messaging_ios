Pod::Spec.new do |s|
  s.name             = 'PolyVoice'
  # Keep in sync with Sources/PolyMessaging/Public/Version.swift and CHANGELOG.md.
  s.version          = '0.11.0'
  s.summary          = 'WebRTC voice calling for the PolyAI iOS SDK.'
  s.description      = <<-DESC
    PolyVoice adds live, two-way WebRTC voice calls to a PolyAI agent — the
    companion to PolyMessaging. It ships as a SEPARATE pod so chat-only apps
    never link the WebRTC binary. Reuses the messaging Configuration and the
    same CallState / PolyError types.
  DESC
  s.homepage         = 'https://github.com/polyai/ios-sdk'
  s.license          = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author           = { 'PolyAI Limited' => 'messaging-pod@poly-ai.com' }
  s.source           = { :git => 'https://github.com/polyai/ios-sdk.git', :tag => "v#{s.version}" }

  s.swift_version            = '5.9'
  s.ios.deployment_target    = '15.0'  # iOS-only: WebRTC audio is not available on macOS.

  s.source_files     = 'Sources/PolyVoice/**/*.swift'

  s.dependency 'PolyMessaging', "#{s.version}"
  s.dependency 'WebRTC-lib', '149.0.0'  # exact — matches the SPM pin (stasel/WebRTC's pod; M141 is broken for SPM)
end
