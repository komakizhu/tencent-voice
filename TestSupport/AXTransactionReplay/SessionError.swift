// Compile-only stand-in for the unrelated SessionCoordinator error type.
// No replay exercises session, audio, credentials, or permission handling.
enum SessionError: Error {
    case credentialsMissing, microphoneDenied, noTextTarget, busy, cancelled
}
