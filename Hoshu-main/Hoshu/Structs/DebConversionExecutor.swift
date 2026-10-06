import AuxiliaryExecute
import Foundation

@MainActor
final class DebConversionExecutor {
    private var isRunning = false
    private var didComplete = false
    private var executionTask: Task<Void, Never>?
    private var outputHandler: (String) -> Void
    private var completionHandler: (Bool) -> Void
    private var convertedFilePath: String?
    private var onConvertedFileFound: ((String) -> Void)?
    private let convertedDirectory = "/tmp/moe.waru.hoshu/.converted/"
    private var conversionSucceeded = false
    private var conversionOperationID: UUID?
    var conversionSucceededValue: Bool { conversionSucceeded }

    private func shortOperationID(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return String(id.uuidString.prefix(8))
    }

    private func logLifecycle(_ message: String, operationID: UUID? = nil) {
        if let shortID = shortOperationID(operationID) {
            NSLog("[Hoshu][Convert][\(shortID)] \(message)")
        } else {
            NSLog("[Hoshu][Convert] \(message)")
        }
    }

    private enum ConvertTransition: String {
        case idle
        case running
        case outputDetected
        case completed
        case stopped
        case failed
    }

    private func logTransition(
        from: ConvertTransition,
        to: ConvertTransition,
        operationID: UUID? = nil,
        note: String? = nil
    ) {
        let transitionText = "state \(from.rawValue) -> \(to.rawValue)"
        if let note, !note.isEmpty {
            logLifecycle(
                "\(transitionText) (\(note))",
                operationID: operationID
            )
        } else {
            logLifecycle(transitionText, operationID: operationID)
        }
    }

    init(
        outputHandler: @escaping (String) -> Void = { _ in },
        completionHandler: @escaping (Bool) -> Void,
        onConvertedFileFound: ((String) -> Void)? = nil
    ) {
        self.outputHandler = outputHandler
        self.completionHandler = completionHandler
        self.onConvertedFileFound = onConvertedFileFound
    }

    func start(withFilePath filePath: String) {
        let operationID = UUID()

        if isRunning {
            logLifecycle(
                "Ignored start request because conversion is already running",
                operationID: conversionOperationID
            )
            return
        }

        conversionOperationID = operationID
        logLifecycle(
            "Starting conversion for \(filePath)",
            operationID: operationID
        )
        logTransition(from: .idle, to: .running, operationID: operationID)

        isRunning = true
        didComplete = false
        executionTask?.cancel()
        executionTask = nil

        outputHandler("[+] Loading file from \(filePath)...\n")

        let environmentPath: [String] =
            ProcessInfo.processInfo.environment["PATH"]?
            .components(separatedBy: ":")
            .compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { path in
                if path.hasPrefix("/var/jb/") {
                    return path
                } else {
                    return "/var/jb/" + path
                }
            } ?? []

        executionTask = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else {
                await MainActor.run {
                    self.logLifecycle(
                        "Execution task cancelled before spawn",
                        operationID: operationID
                    )
                }
                return
            }

            AuxiliaryExecute.spawn(
                command: "/var/jb/usr/local/bin/rootless-patcher",
                args: [filePath],
                environment: ["PATH": environmentPath.joined(separator: ":")],
                timeout: 0,
                stdoutBlock: { [weak self] stdout in
                    guard let self = self else { return }
                    Task { @MainActor in
                        guard self.isRunning else { return }
                        self.outputHandler(stdout)
                        self.captureConvertedPath(from: stdout)
                    }
                },
                stderrBlock: { [weak self] stderr in
                    guard let self = self else { return }
                    Task { @MainActor in
                        guard self.isRunning else { return }
                        self.outputHandler("[+] Error: \(stderr)")
                    }
                }
            ) { [weak self] _ in
                guard let self = self else { return }
                Task { @MainActor in
                    guard self.isRunning else { return }
                    self.outputHandler(
                        "\n[+] Job completed. You may close this window.\n"
                    )
                    if !self.conversionSucceeded {
                        self.outputHandler(
                            "\n[+] No converted file was produced. The conversion may have failed.\n"
                        )
                    }

                    self.isRunning = false
                    self.executionTask = nil
                    self.logLifecycle(
                        "Conversion process completed. success=\(self.conversionSucceeded)",
                        operationID: operationID
                    )
                    self.finish(success: self.conversionSucceeded)
                }
            }
        }
    }

    private func captureConvertedPath(from output: String) {
        guard output.contains("Done! New .deb path: ") else { return }

        logLifecycle(
            "Detected converted package path in process output",
            operationID: conversionOperationID
        )
        logTransition(
            from: .running,
            to: .outputDetected,
            operationID: conversionOperationID
        )

        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            guard line.contains("Done! New .deb path: ") else { continue }
            guard let range = line.range(of: "Done! New .deb path: ") else {
                continue
            }

            let convertedPath = String(line[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: convertedDirectory) {
                do {
                    try fileManager.createDirectory(
                        atPath: convertedDirectory,
                        withIntermediateDirectories: true
                    )
                } catch {
                    continue
                }
            }

            let convertedFilename = URL(fileURLWithPath: convertedPath)
                .lastPathComponent
            let newPath = convertedDirectory + convertedFilename

            do {
                if fileManager.fileExists(atPath: newPath) {
                    try fileManager.removeItem(atPath: newPath)
                }

                try fileManager.moveItem(atPath: convertedPath, toPath: newPath)
                convertedFilePath = newPath
                onConvertedFileFound?(newPath)
                conversionSucceeded = true
                logLifecycle(
                    "Moved converted package to managed path: \(newPath)",
                    operationID: conversionOperationID
                )
            } catch {
                convertedFilePath = convertedPath
                if let convertedFilePath {
                    onConvertedFileFound?(convertedFilePath)
                    conversionSucceeded = true
                    logLifecycle(
                        "Using converted package at original path: \(convertedFilePath)",
                        operationID: conversionOperationID
                    )
                }
            }
        }
    }

    func stop() {
        logLifecycle(
            "Stopping conversion and cancelling execution task",
            operationID: conversionOperationID
        )
        logTransition(
            from: .running,
            to: .stopped,
            operationID: conversionOperationID
        )
        executionTask?.cancel()
        executionTask = nil
        isRunning = false
        finish(success: false)
    }

    private func finish(success: Bool) {
        if didComplete { return }
        didComplete = true
        logLifecycle(
            "Finishing conversion callback. success=\(success)",
            operationID: conversionOperationID
        )
        logTransition(
            from: .running,
            to: success ? .completed : .failed,
            operationID: conversionOperationID
        )
        conversionOperationID = nil
        completionHandler(success)
    }
}
