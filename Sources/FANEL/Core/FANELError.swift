import Foundation

indirect enum FANELError: Error, LocalizedError, CustomStringConvertible {
    case claudeNotFound
    case processStartFailed(underlying: Error)
    case processCrashed(exitCode: Int32)
    case timeout(seconds: Int)
    case stdinWriteFailed
    case jsonParseFailed(rawOutput: String)
    case retryExhausted(lastError: FANELError)
    case serverStartFailed(underlying: Error)
    case serverAlreadyRunning
    case serverNotRunning
    case resourceNotFound(name: String)
    case hayabusaUnavailable
    case modelNotFound(name: String)
    case benchmarkFailed(model: String)
    case workerLayerExhausted
    case tailscaleNotInstalled
    case tailscaleNotConnected
    case ownershipConflict(currentOwner: String)
    case peerUnreachable(hostname: String)
    case gitPushFailed(reason: String)

    var description: String {
        switch self {
        case .claudeNotFound:
            return "Claude binary not found in PATH"
        case .processStartFailed(let error):
            return "Failed to start Claude process: \(error)"
        case .processCrashed(let code):
            return "Claude process crashed with exit code: \(code)"
        case .timeout(let seconds):
            return "Claude process timed out after \(seconds)s"
        case .stdinWriteFailed:
            return "Failed to write to Claude stdin"
        case .jsonParseFailed(let raw):
            return "JSON parse failed. Raw output: \(raw.prefix(200))"
        case .retryExhausted(let last):
            return "Retry exhausted. Last error: \(last)"
        case .serverStartFailed(let error):
            return "Failed to start Vapor server: \(error)"
        case .serverAlreadyRunning:
            return "Server is already running"
        case .serverNotRunning:
            return "Server is not running"
        case .resourceNotFound(let name):
            return "Resource not found: \(name)"
        case .hayabusaUnavailable:
            return "Hayabusa inference engine is not available"
        case .modelNotFound(let name):
            return "Model not found: \(name)"
        case .benchmarkFailed(let model):
            return "Benchmark failed for model: \(model)"
        case .workerLayerExhausted:
            return "All worker layers exhausted"
        case .tailscaleNotInstalled:
            return "Tailscale is not installed"
        case .tailscaleNotConnected:
            return "Tailscale is not connected"
        case .ownershipConflict(let owner):
            return "Ownership conflict: currently owned by \(owner)"
        case .peerUnreachable(let host):
            return "Peer unreachable: \(host)"
        case .gitPushFailed(let reason):
            return "Git push failed: \(reason)"
        }
    }

    var errorDescription: String? { description }
}
