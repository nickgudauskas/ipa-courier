import Foundation

/// A command that exited with a non-zero status.
struct CommandError: LocalizedError {
    let command: String
    let status: Int32
    let output: String

    var errorDescription: String? {
        let tail = output
            .split(whereSeparator: \.isNewline)
            .suffix(15)
            .joined(separator: "\n")
        return "\(command) failed (exit \(status)).\n\(tail)"
    }
}

/// Thread-safe byte accumulator for process output.
final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); data.append(chunk); lock.unlock()
    }

    var value: Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}

enum Shell {
    struct Result {
        let status: Int32
        let output: Data
        var text: String { String(decoding: output, as: UTF8.self) }
    }

    /// Runs a process asynchronously, streaming output to `onOutput`.
    /// Cancelling the calling task terminates the process.
    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String],
        mergeStderr: Bool = true,
        checkStatus: Bool = true,
        onStart: (@Sendable (Int32) -> Void)? = nil,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = mergeStderr ? outPipe : errPipe

        let buffer = OutputBuffer()
        let errBuffer = OutputBuffer()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            buffer.append(chunk)
            onOutput?(String(decoding: chunk, as: UTF8.self))
        }
        if !mergeStderr {
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { errBuffer.append(chunk) }
            }
        }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    let rest = (try? outPipe.fileHandleForReading.readToEnd()) ?? nil
                    if let rest, !rest.isEmpty {
                        buffer.append(rest)
                        onOutput?(String(decoding: rest, as: UTF8.self))
                    }
                    if !mergeStderr,
                       let errRest = (try? errPipe.fileHandleForReading.readToEnd()) ?? nil {
                        errBuffer.append(errRest)
                    }
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                    onStart?(process.processIdentifier)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        try Task.checkCancellation()

        if checkStatus && status != 0 {
            let name = ([URL(fileURLWithPath: executable).lastPathComponent] + arguments.prefix(3))
                .joined(separator: " ")
            var combined = buffer.value
            combined.append(errBuffer.value)
            throw CommandError(command: name, status: status,
                               output: String(decoding: combined, as: UTF8.self))
        }
        return Result(status: status, output: buffer.value)
    }
}

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
