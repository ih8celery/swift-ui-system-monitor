import Darwin
import Foundation

/// Launches one executable with an argument array and captures what it printed. Never a shell:
/// this app reads process and network state, so interpolation would be a real hazard.
public enum ProcessRunner {
    /// How long a child may run before it is killed, when the caller says nothing.
    public static let defaultTimeout: TimeInterval = 15

    public static func run(
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

public struct CommandOutput {
    public let output: String
    public let error: String
    public let status: Int32
    /// True only when the wall-clock timeout killed the child. A killed child's stdio
    /// buffer dies with it, so callers must read an empty `output` as "no answer yet",
    /// not as "the command answered nothing".
    public let didTimeout: Bool

    public init(output: String, error: String, status: Int32, didTimeout: Bool) {
        self.output = output
        self.error = error
        self.status = status
        self.didTimeout = didTimeout
    }
}

/// Accumulates bytes delivered from a `FileHandle.readabilityHandler`; macOS
/// invokes stdout's and stderr's handlers concurrently on separate queues.
private final class PipeBuffer {
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

