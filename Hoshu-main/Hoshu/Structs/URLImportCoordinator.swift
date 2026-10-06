import Foundation
import SwiftUI

@MainActor
final class URLImportCoordinator: ObservableObject {
    @Published var showURLImportPrompt = false
    @Published var urlToImport: String = ""
    @Published var isDownloading = false
    @Published var downloadErrorAlert: DownloadErrorAlert? = nil
    @Published var downloadProgress: Double = 0.0
    @Published var isPreflighting = false
    @Published var downloadSpeedBytesPerSec: Double = 0
    @Published var downloadETASeconds: Double = 0
    @Published var isUnknownSize: Bool = false
    @Published var downloadedBytes: Int64 = 0
    @Published var retryAttempt: Int = 0

    private var activeDownloader: DebURLDownloader? = nil
    private var retryTask: Task<Void, Never>? = nil
    private var cancelRequested: Bool = false
    private var downloadOperationID: UUID? = nil
    private let maxDownloadRetries: Int = 3

    private enum DownloadTransitionState: String {
        case idle
        case preflighting
        case retrying
        case downloading
        case finalizing
        case handoffToExtract
        case cancelled
        case failed
    }

    func beginPromptIfIdle() {
        guard !isDownloading && !isPreflighting else { return }
        urlToImport = ""
        showURLImportPrompt = true
    }

    func submitFromAlert(
        ensureTempDirectoryExists: @escaping () -> Void,
        setParsingDeb: @escaping (Bool) -> Void,
        log:
            @escaping (_ area: String, _ message: String, _ operationID: UUID?)
            -> Void,
        onDownloadFinalized: @escaping (_ filePath: String) -> Void,
        importingDirectory: String
    ) {
        guard !isPreflighting && !isDownloading else { return }
        let normalized = URLImportSupport.normalizeURLInput(urlToImport)
        guard URLImportSupport.isPotentiallyValidURL(normalized) else {
            downloadErrorAlert = DownloadErrorAlert(
                message: "Please enter a valid http(s) URL."
            )
            return
        }
        urlToImport = normalized
        startURLPreflight(
            ensureTempDirectoryExists: ensureTempDirectoryExists,
            setParsingDeb: setParsingDeb,
            log: log,
            onDownloadFinalized: onDownloadFinalized,
            importingDirectory: importingDirectory
        )
    }

    func cancel(
        setParsingDeb: @escaping (Bool) -> Void,
        log:
            @escaping (_ area: String, _ message: String, _ operationID: UUID?)
            -> Void
    ) {
        log(
            "Download",
            "Cancellation requested",
            downloadOperationID
        )
        logTransition(
            from: .downloading,
            to: .cancelled,
            operationID: downloadOperationID,
            log: log
        )
        cancelRequested = true
        retryTask?.cancel()
        retryTask = nil
        activeDownloader?.cancel()
        activeDownloader = nil
        downloadOperationID = nil
        isDownloading = false
        isPreflighting = false
        setParsingDeb(false)
        downloadProgress = 0
        downloadSpeedBytesPerSec = 0
        downloadETASeconds = 0
        downloadedBytes = 0
        isUnknownSize = false
    }

    func reset() {
        cancelRequested = true
        retryTask?.cancel()
        retryTask = nil
        activeDownloader?.cancel()
        activeDownloader = nil
        showURLImportPrompt = false
        urlToImport = ""
        isDownloading = false
        downloadErrorAlert = nil
        downloadProgress = 0
        isPreflighting = false
        downloadSpeedBytesPerSec = 0
        downloadETASeconds = 0
        isUnknownSize = false
        downloadedBytes = 0
        retryAttempt = 0
        downloadOperationID = nil
        cancelRequested = false
    }

    private func startURLPreflight(
        ensureTempDirectoryExists: @escaping () -> Void,
        setParsingDeb: @escaping (Bool) -> Void,
        log:
            @escaping (_ area: String, _ message: String, _ operationID: UUID?)
            -> Void,
        onDownloadFinalized: @escaping (_ filePath: String) -> Void,
        importingDirectory: String
    ) {
        let raw = urlToImport.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URLImportSupport.isPotentiallyValidURL(raw),
            let url = URL(string: raw)
        else {
            return
        }
        let operationID = UUID()
        downloadOperationID = operationID
        log(
            "Download",
            "Starting preflight for \(url.absoluteString)",
            operationID
        )
        logTransition(
            from: .idle,
            to: .preflighting,
            operationID: operationID,
            log: log
        )
        showURLImportPrompt = false
        isPreflighting = true
        downloadProgress = 0
        downloadErrorAlert = nil
        downloadedBytes = 0
        downloadSpeedBytesPerSec = 0
        downloadETASeconds = 0
        isUnknownSize = false
        retryAttempt = 0
        cancelRequested = false
        retryTask?.cancel()
        retryTask = nil
        ensureTempDirectoryExists()

        var headRequest = URLRequest(url: url)
        headRequest.httpMethod = "HEAD"

        let headTask = URLSession.shared.dataTask(with: headRequest) {
            _,
            response,
            error in
            if error != nil {
                Task { @MainActor in
                    if !self.cancelRequested {
                        log(
                            "Download",
                            "HEAD preflight failed; falling back to direct download",
                            operationID
                        )
                        self.isPreflighting = false
                        self.startDownloadWithRetry(
                            url: url,
                            resolvedFilename: url.lastPathComponent,
                            operationID: operationID,
                            setParsingDeb: setParsingDeb,
                            log: log,
                            onDownloadFinalized: onDownloadFinalized,
                            importingDirectory: importingDirectory
                        )
                    }
                }
                return
            }
            guard let http = response as? HTTPURLResponse else {
                Task { @MainActor in
                    if !self.cancelRequested {
                        log(
                            "Download",
                            "HEAD preflight returned non-HTTP response; falling back",
                            operationID
                        )
                        self.isPreflighting = false
                        self.startDownloadWithRetry(
                            url: url,
                            resolvedFilename: url.lastPathComponent,
                            operationID: operationID,
                            setParsingDeb: setParsingDeb,
                            log: log,
                            onDownloadFinalized: onDownloadFinalized,
                            importingDirectory: importingDirectory
                        )
                    }
                }
                return
            }
            if http.statusCode == 405 {
                Task { @MainActor in
                    if !self.cancelRequested {
                        log(
                            "Download",
                            "HEAD not allowed (405); falling back to direct download",
                            operationID
                        )
                        self.isPreflighting = false
                        self.startDownloadWithRetry(
                            url: url,
                            resolvedFilename: url.lastPathComponent,
                            operationID: operationID,
                            setParsingDeb: setParsingDeb,
                            log: log,
                            onDownloadFinalized: onDownloadFinalized,
                            importingDirectory: importingDirectory
                        )
                    }
                }
                return
            }
            guard (200..<400).contains(http.statusCode) else {
                Task { @MainActor in
                    if !self.cancelRequested {
                        log(
                            "Download",
                            "HEAD preflight rejected with status \(http.statusCode)",
                            operationID
                        )
                        self.isPreflighting = false
                        self.handleDownloadError(
                            "HEAD status \(http.statusCode)",
                            operationID: operationID,
                            setParsingDeb: setParsingDeb,
                            log: log
                        )
                    }
                }
                return
            }
            let contentDisp = http.value(
                forHTTPHeaderField: "Content-Disposition"
            )
            let resolvedName = URLImportSupport.resolveFilename(
                originalURL: url,
                contentDisposition: contentDisp
            )
            Task { @MainActor in
                if !self.cancelRequested {
                    log(
                        "Download",
                        "Preflight succeeded; resolved filename \(resolvedName)",
                        operationID
                    )
                    self.isPreflighting = false
                    self.startDownloadWithRetry(
                        url: url,
                        resolvedFilename: resolvedName,
                        operationID: operationID,
                        setParsingDeb: setParsingDeb,
                        log: log,
                        onDownloadFinalized: onDownloadFinalized,
                        importingDirectory: importingDirectory
                    )
                }
            }
        }
        headTask.resume()
    }

    private func startDownloadWithRetry(
        url: URL,
        resolvedFilename: String,
        operationID: UUID? = nil,
        setParsingDeb: @escaping (Bool) -> Void,
        log:
            @escaping (_ area: String, _ message: String, _ operationID: UUID?)
            -> Void,
        onDownloadFinalized: @escaping (_ filePath: String) -> Void,
        importingDirectory: String
    ) {
        let effectiveOperationID = operationID ?? UUID()
        downloadOperationID = effectiveOperationID
        log(
            "Download",
            "Starting retry workflow for \(resolvedFilename)",
            effectiveOperationID
        )
        logTransition(
            from: .preflighting,
            to: .retrying,
            operationID: effectiveOperationID,
            log: log
        )
        retryAttempt = 0
        retryTask?.cancel()
        retryTask = nil
        attemptDownload(
            url: url,
            resolvedFilename: resolvedFilename,
            attempt: 1,
            operationID: effectiveOperationID,
            setParsingDeb: setParsingDeb,
            log: log,
            onDownloadFinalized: onDownloadFinalized,
            importingDirectory: importingDirectory
        )
    }

    private func attemptDownload(
        url: URL,
        resolvedFilename: String,
        attempt: Int,
        operationID: UUID,
        setParsingDeb: @escaping (Bool) -> Void,
        log:
            @escaping (_ area: String, _ message: String, _ operationID: UUID?)
            -> Void,
        onDownloadFinalized: @escaping (_ filePath: String) -> Void,
        importingDirectory: String
    ) {
        if cancelRequested { return }
        log(
            "Download",
            "Attempt \(attempt) for \(resolvedFilename)",
            operationID
        )
        retryAttempt = attempt - 1
        beginDownload(
            url: url,
            resolvedFilename: resolvedFilename,
            attempt: attempt,
            operationID: operationID,
            setParsingDeb: setParsingDeb,
            log: log,
            onDownloadFinalized: onDownloadFinalized,
            importingDirectory: importingDirectory
        )
    }

    private func beginDownload(
        url: URL,
        resolvedFilename: String,
        attempt: Int,
        operationID: UUID,
        setParsingDeb: @escaping (Bool) -> Void,
        log:
            @escaping (_ area: String, _ message: String, _ operationID: UUID?)
            -> Void,
        onDownloadFinalized: @escaping (_ filePath: String) -> Void,
        importingDirectory: String
    ) {
        log(
            "Download",
            "Begin transfer attempt \(attempt) for \(resolvedFilename)",
            operationID
        )
        logTransition(
            from: .retrying,
            to: .downloading,
            operationID: operationID,
            note: "attempt \(attempt)",
            log: log
        )
        isDownloading = true
        setParsingDeb(true)
        let downloader = DebURLDownloader(
            progressHandler: { progress, bytesWritten, totalBytes, startedAt in
                Task { @MainActor in
                    self.downloadProgress = progress
                    self.downloadedBytes = bytesWritten
                    if totalBytes > 0 {
                        let elapsed = Date().timeIntervalSince(startedAt)
                        if elapsed > 0 {
                            self.downloadSpeedBytesPerSec =
                                Double(bytesWritten) / elapsed
                            let remainingBytes = Double(
                                totalBytes - bytesWritten
                            )
                            if self.downloadSpeedBytesPerSec > 0 {
                                self.downloadETASeconds =
                                    remainingBytes
                                    / self.downloadSpeedBytesPerSec
                            }
                        }
                        self.isUnknownSize = false
                    } else {
                        self.isUnknownSize = true
                    }
                }
            },
            completion: { tempURL, error in
                if let error = error {
                    Task { @MainActor in
                        if self.cancelRequested { return }
                        if URLImportSupport.isTransientError(error)
                            && attempt < self.maxDownloadRetries
                        {
                            let delay = pow(2.0, Double(attempt - 1))
                            log(
                                "Download",
                                "Transient error on attempt \(attempt): \(error.localizedDescription). Retrying in \(Int(delay))s",
                                operationID
                            )
                            self.retryTask?.cancel()
                            self.retryTask = Task {
                                let delayNanoseconds = UInt64(
                                    delay * 1_000_000_000
                                )
                                try? await Task.sleep(
                                    nanoseconds: delayNanoseconds
                                )
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    self.attemptDownload(
                                        url: url,
                                        resolvedFilename: resolvedFilename,
                                        attempt: attempt + 1,
                                        operationID: operationID,
                                        setParsingDeb: setParsingDeb,
                                        log: log,
                                        onDownloadFinalized:
                                            onDownloadFinalized,
                                        importingDirectory: importingDirectory
                                    )
                                }
                            }
                        } else {
                            log(
                                "Download",
                                "Download failed on attempt \(attempt): \(error.localizedDescription)",
                                operationID
                            )
                            self.handleDownloadError(
                                error.localizedDescription,
                                operationID: operationID,
                                setParsingDeb: setParsingDeb,
                                log: log
                            )
                        }
                    }
                    return
                }
                guard let tempURL else {
                    Task { @MainActor in
                        self.handleDownloadError(
                            "No data",
                            operationID: operationID,
                            setParsingDeb: setParsingDeb,
                            log: log
                        )
                    }
                    return
                }
                Task { @MainActor in
                    self.finalizeDownload(
                        tempURL: tempURL,
                        filename: resolvedFilename,
                        operationID: operationID,
                        setParsingDeb: setParsingDeb,
                        log: log,
                        onDownloadFinalized: onDownloadFinalized,
                        importingDirectory: importingDirectory
                    )
                }
            }
        )
        activeDownloader = downloader
        downloader.start(url: url)
    }

    private func finalizeDownload(
        tempURL: URL,
        filename: String,
        operationID: UUID,
        setParsingDeb: @escaping (Bool) -> Void,
        log:
            @escaping (_ area: String, _ message: String, _ operationID: UUID?)
            -> Void,
        onDownloadFinalized: @escaping (_ filePath: String) -> Void,
        importingDirectory: String
    ) {
        logTransition(
            from: .downloading,
            to: .finalizing,
            operationID: operationID,
            log: log
        )
        let fileManager = FileManager.default
        let cleanedName = filename.cleanIOSFileSuffix()
        let destinationPath = importingDirectory + cleanedName
        do {
            if fileManager.fileExists(atPath: destinationPath) {
                try fileManager.removeItem(atPath: destinationPath)
            }
            try fileManager.copyItem(
                at: tempURL,
                to: URL(fileURLWithPath: destinationPath)
            )
            isDownloading = false
            activeDownloader = nil
            retryTask?.cancel()
            retryTask = nil
            setParsingDeb(true)
            log(
                "Download",
                "Download finalized at \(destinationPath); starting extraction",
                operationID
            )
            logTransition(
                from: .finalizing,
                to: .handoffToExtract,
                operationID: operationID,
                log: log
            )
            clearDownloadOperationIDIfMatches(operationID)
            onDownloadFinalized(destinationPath)
        } catch {
            handleDownloadError(
                error.localizedDescription,
                operationID: operationID,
                setParsingDeb: setParsingDeb,
                log: log
            )
        }
    }

    private func handleDownloadError(
        _ message: String,
        operationID: UUID? = nil,
        setParsingDeb: @escaping (Bool) -> Void,
        log:
            @escaping (_ area: String, _ message: String, _ operationID: UUID?)
            -> Void
    ) {
        let effectiveOperationID = operationID ?? downloadOperationID
        log(
            "Download",
            "Download workflow failed: \(message)",
            effectiveOperationID
        )
        logTransition(
            from: .downloading,
            to: .failed,
            operationID: effectiveOperationID,
            note: message,
            log: log
        )
        downloadErrorAlert = DownloadErrorAlert(message: message)
        retryTask?.cancel()
        retryTask = nil
        activeDownloader = nil
        if let effectiveOperationID {
            clearDownloadOperationIDIfMatches(effectiveOperationID)
        } else {
            downloadOperationID = nil
        }
        isDownloading = false
        isPreflighting = false
        setParsingDeb(false)
        downloadProgress = 0
        downloadSpeedBytesPerSec = 0
        downloadETASeconds = 0
        downloadedBytes = 0
        isUnknownSize = false
    }

    private func clearDownloadOperationIDIfMatches(_ id: UUID) {
        if downloadOperationID == id {
            downloadOperationID = nil
        }
    }

    private func logTransition(
        from: DownloadTransitionState,
        to: DownloadTransitionState,
        operationID: UUID? = nil,
        note: String? = nil,
        log:
            @escaping (_ area: String, _ message: String, _ operationID: UUID?)
            -> Void
    ) {
        let transitionText = "state \(from.rawValue) -> \(to.rawValue)"
        if let note, !note.isEmpty {
            log("Download", "\(transitionText) (\(note))", operationID)
        } else {
            log("Download", transitionText, operationID)
        }
    }
}
