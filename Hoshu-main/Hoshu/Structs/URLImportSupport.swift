import Foundation

struct URLImportSupport {
    static func normalizeURLInput(_ rawInput: String) -> String {
        var normalized = rawInput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        let wrapperPairs: [(Character, Character)] = [
            ("\"", "\""),
            ("'", "'"),
            ("<", ">"),
            ("(", ")"),
            ("[", "]"),
            ("{", "}"),
        ]

        var didStrip = true
        while didStrip, normalized.count >= 2 {
            didStrip = false
            for (open, close) in wrapperPairs {
                guard normalized.first == open, normalized.last == close else {
                    continue
                }
                normalized = String(normalized.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                didStrip = true
                break
            }
        }

        if normalized.lowercased().hasPrefix("www.") {
            normalized = "https://" + normalized
        }

        return normalized
    }

    static func isPotentiallyValidURL(_ text: String) -> Bool {
        guard
            let url = URL(
                string: text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        else {
            return false
        }
        return url.scheme == "http" || url.scheme == "https"
    }

    static func formatBytes(_ bytesPerSec: Double) -> String {
        if bytesPerSec <= 0 { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = bytesPerSec
        var idx = 0
        while value > 1024 && idx < units.count - 1 {
            value /= 1024
            idx += 1
        }
        let formattedValue = value.formatted(
            .number.precision(.fractionLength(idx == 0 ? 0 : 1))
        )
        return "\(formattedValue) \(units[idx])"
    }

    static func formatPercent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    static func formatETA(_ seconds: Double) -> String {
        if seconds.isNaN || seconds.isInfinite || seconds <= 0 {
            return "ETA --"
        }
        if seconds < 60 {
            return "ETA \(Int(seconds.rounded()))s"
        }
        let mins = Int(seconds / 60)
        let secs = Int(seconds) % 60
        if mins < 60 {
            let paddedSeconds = secs.formatted(
                .number.precision(.integerLength(2...))
            )
            return "ETA \(mins)m \(paddedSeconds)s"
        }
        let hours = mins / 60
        let remMins = mins % 60
        return "ETA \(hours)h \(remMins)m"
    }

    static func resolveFilename(
        originalURL: URL,
        contentDisposition: String?
    ) -> String {
        if let cd = contentDisposition {
            // Look for filename="..."
            if let range = cd.range(of: "filename=") {
                let after = cd[range.upperBound...]
                let trimmed = after.trimmingCharacters(
                    in: CharacterSet(charactersIn: "\"' ;")
                )
                let components =
                    trimmed.components(separatedBy: ";").first ?? trimmed
                if !components.isEmpty { return components }
            }
        }
        return originalURL.lastPathComponent
    }

    static func isTransientError(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        let transientCodes: Set<Int> = [
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorResourceUnavailable,
            NSURLErrorInternationalRoamingOff,
            NSURLErrorCallIsActive,
            NSURLErrorDataNotAllowed,
            NSURLErrorSecureConnectionFailed,
            NSURLErrorCannotLoadFromNetwork,
        ]
        return transientCodes.contains(ns.code)
    }
}
