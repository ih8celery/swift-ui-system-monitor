import AppKit
import Darwin
import Foundation
import SwiftUI

extension UnifiedMonitor {
    static func runProcess(path: String, arguments: [String], timeout: TimeInterval = 15) -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

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

struct CommandOutput {
    let output: String
    let error: String
    let status: Int32
    /// True only when the wall-clock timeout killed the child. A killed child's stdio
    /// buffer dies with it, so callers must read an empty `output` as "no answer yet",
    /// not as "the command answered nothing".
    let didTimeout: Bool
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

