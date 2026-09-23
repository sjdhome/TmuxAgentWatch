import Darwin
import Foundation

nonisolated struct SubprocessResult: Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

nonisolated enum SubprocessFailure: Error, Equatable {
    case timedOut
    case outputLimitExceeded
    case readFailed(Int32)
}

/// Bounded, cancellable execution. Only the direct child is owned and signalled.
/// Both pipes are nonblocking and drained on the same serial queue; no reader
/// thread or child survives cancellation, a deadline, or an output-limit failure.
nonisolated enum SubprocessRunner {
    static func run(
        _ path: String, _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 5, outputLimit: Int = 8 * 1024 * 1024
    ) async throws -> SubprocessResult {
        let execution = SubprocessExecution(
            path: path, arguments: arguments, environment: environment,
            timeout: timeout, outputLimit: outputLimit)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                execution.start(continuation)
            }
        } onCancel: {
            execution.cancel()
        }
    }
}

/// All mutable state is confined to `queue`, including cancellation before launch.
nonisolated private final class SubprocessExecution: @unchecked Sendable {
    private let queue = DispatchQueue(label: "TmuxAgentWatch.subprocess", qos: .utility)
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let timeout: TimeInterval
    private let outputLimit: Int
    private var continuation: CheckedContinuation<SubprocessResult, any Error>?
    private var readers: [DispatchSourceRead?] = [nil, nil]
    private var registeredReaders = [false, false]
    private var buffers = [Data(), Data()]
    private var deadline: DispatchWorkItem?
    private var killDeadline: DispatchWorkItem?
    private var failure: (any Error)?
    private var launched = false
    private var exited = false
    private var finished = false

    init(
        path: String, arguments: [String], environment: [String: String],
        timeout: TimeInterval, outputLimit: Int
    ) {
        self.timeout = timeout
        self.outputLimit = outputLimit
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    func start(_ continuation: CheckedContinuation<SubprocessResult, any Error>) {
        queue.async { self.launch(continuation) }
    }

    func cancel() {
        queue.async { self.abort(CancellationError()) }
    }

    private func launch(_ continuation: CheckedContinuation<SubprocessResult, any Error>) {
        self.continuation = continuation
        if failure != nil {
            finishIfReady()
            return
        }
        process.terminationHandler = { [self] _ in
            queue.async {
                self.exited = true
                self.finishIfReady()
            }
        }
        do {
            try process.run()
            launched = true
            // The parent must not keep the write ends open after spawning.
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            try startReader(stdoutPipe.fileHandleForReading, index: 0)
            try startReader(stderrPipe.fileHandleForReading, index: 1)
            let work = DispatchWorkItem { [weak self] in
                self?.abort(SubprocessFailure.timedOut)
            }
            deadline = work
            queue.asyncAfter(deadline: .now() + timeout, execute: work)
        } catch {
            abort(error)
        }
    }

    private func startReader(_ handle: FileHandle, index: Int) throws {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags != -1, fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw SubprocessFailure.readFailed(errno)
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain(fd, index: index) }
        source.setCancelHandler { try? handle.close() }
        readers[index] = source
        registeredReaders[index] = true
        source.resume()
    }

    private func drain(_ fd: Int32, index: Int) {
        guard !finished, failure == nil else { return }
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        // Yield regularly so a continuously writing child cannot starve the
        // deadline or cancellation queued alongside these read events.
        for _ in 0..<16 {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                guard buffers[0].count + buffers[1].count + count <= outputLimit else {
                    abort(SubprocessFailure.outputLimitExceeded)
                    return
                }
                buffers[index].append(contentsOf: bytes.prefix(count))
            } else if count == 0 {
                readers[index]?.cancel()
                readers[index] = nil
                finishIfReady()
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                abort(SubprocessFailure.readFailed(errno))
                return
            }
        }
    }

    private func abort(_ error: any Error) {
        guard !finished else { return }
        if failure == nil { failure = error }
        for index in readers.indices {
            readers[index]?.cancel()
            readers[index] = nil
        }
        if launched && !exited && process.isRunning {
            process.terminate()
            if killDeadline == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, !self.finished, self.process.isRunning else { return }
                    _ = Darwin.kill(self.process.processIdentifier, SIGKILL)
                }
                killDeadline = work
                queue.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
            }
        }
        finishIfReady()
    }

    private func finishIfReady() {
        guard !finished, let continuation,
            !launched || exited, readers.allSatisfy({ $0 == nil })
        else { return }
        finished = true
        self.continuation = nil
        deadline?.cancel()
        killDeadline?.cancel()
        process.terminationHandler = nil
        // Registered descriptors are closed only by their cancellation handlers.
        if !registeredReaders[0] { try? stdoutPipe.fileHandleForReading.close() }
        if !registeredReaders[1] { try? stderrPipe.fileHandleForReading.close() }
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        if let failure {
            continuation.resume(throwing: failure)
        } else {
            continuation.resume(
                returning: SubprocessResult(
                    exitCode: process.terminationStatus,
                    stdout: String(decoding: buffers[0], as: UTF8.self),
                    stderr: String(decoding: buffers[1], as: UTF8.self)))
        }
    }
}
