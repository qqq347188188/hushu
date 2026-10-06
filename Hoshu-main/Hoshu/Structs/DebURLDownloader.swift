import Foundation

// Downloader with progress via delegate
class DebURLDownloader: NSObject, URLSessionDownloadDelegate {
    private var progressHandler: (Double, Int64, Int64, Date) -> Void
    private var completion: (URL?, Error?) -> Void
    private var session: URLSession!
    private var startTime = Date()

    init(
        progressHandler: @escaping (Double, Int64, Int64, Date) -> Void,
        completion: @escaping (URL?, Error?) -> Void
    ) {
        self.progressHandler = progressHandler
        self.completion = completion
        super.init()
        let config = URLSessionConfiguration.ephemeral
        session = URLSession(
            configuration: config,
            delegate: self,
            delegateQueue: nil
        )
    }

    func start(url: URL) {
        let task = session.downloadTask(with: url)
        task.resume()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesExpectedToWrite > 0 {
            let progress =
                Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            progressHandler(
                progress,
                totalBytesWritten,
                totalBytesExpectedToWrite,
                startTime
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let fileManager = FileManager.default
        let preservedURL = fileManager.temporaryDirectory
            .appendingPathComponent("hoshu-download-\(UUID().uuidString).tmp")

        do {
            if fileManager.fileExists(atPath: preservedURL.path) {
                try fileManager.removeItem(at: preservedURL)
            }
            try fileManager.moveItem(at: location, to: preservedURL)
            completion(preservedURL, nil)
        } catch {
            completion(nil, error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error { completion(nil, error) }
    }
}

extension DebURLDownloader {
    func cancel() {
        session.invalidateAndCancel()
    }
}
