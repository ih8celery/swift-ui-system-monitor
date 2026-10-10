import Darwin
import Foundation

/// Launches one executable with an argument array and captures what it printed. Never a shell:
/// this app reads process and network state, so interpolation would be a real hazard.
public enum ProcessRunner {
    /// How long a child may run before it is killed, when the caller says nothing.
    public static let defaultTimeout: TimeInterval = 15

    /// A non-nil `environment` replaces the child's inherited environment entirely; it does not
    /// merge. To override one key, start from `ProcessInfo.processInfo.environment` and change
    /// that key.
    @Sendable public static func run(
        path: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = defaultTimeout
    ) -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputBuffer = PipeBuffer()
        let errorBuffer = PipeBuffer()
        attachDrain(to: outputPipe, into: outputBuffer)
        attachDrain(to: errorPipe, into: errorBuffer)

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            return CommandOutput(output: "", error: error.localizedDescription, status: -1, didTimeout: false)
        }

        let finishedInTime = exited.wait(timeout: .now() + timeout) == .success
        if !finishedInTime {
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
        }

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil

        let status = finishedInTime ? process.terminationStatus : -1
        return CommandOutput(
            output: String(data: outputBuffer.snapshot(), encoding: .utf8) ?? "",
            error: String(data: errorBuffer.snapshot(), encoding: .utf8) ?? "",
            status: status,
            didTimeout: !finishedInTime
        )
    }

    private static func attachDrain(to pipe: Pipe, into buffer: PipeBuffer) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            buffer.append(chunk)
        }
    }
}

/// What one subprocess run produced: its standard output and error as text, and how it ended.
public struct CommandOutput: Sendable {
    /// Everything the child wrote to standard output, decoded as UTF-8 (empty if it was not UTF-8).
    public let output: String
    /// Everything the child wrote to standard error, decoded as UTF-8; when the executable
    /// could not be started at all, the reason it could not.
    public let error: String
    /// The child's exit status, or -1 when it could not be started or was killed for timing out.
    public let status: Int32
    /// True only when the wall-clock timeout killed the child. A killed child's stdio
    /// buffer dies with it, so callers must read an empty `output` as "no answer yet",
    /// not as "the command answered nothing".
    public let didTimeout: Bool

    /// Builds a result by hand, e.g. for a fake `CommandRunner` in a test.
    public init(output: String, error: String, status: Int32, didTimeout: Bool) {
        self.output = output
        self.error = error
        self.status = status
        self.didTimeout = didTimeout
    }
}

/// Accumulates bytes delivered from a `FileHandle.readabilityHandler`; macOS
/// invokes stdout's and stderr's handlers concurrently on separate queues.
private final class PipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

