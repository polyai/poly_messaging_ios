// Copyright PolyAI Limited

public extension PolyMessaging {
    /// The SDK's released version (SemVer).
    ///
    /// Single source of truth: the `User-Agent` header (`RestApi`) and the
    /// example connect-screen footers read this. Bump it by hand when cutting a
    /// release (mirror the version in `CHANGELOG.md`, then tag `vX.Y.Z`).
    static let version = "0.10.0"
}
