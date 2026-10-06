import AuxiliaryExecute
import Foundation

enum DebPackageExtractionService {
    enum ServiceError: LocalizedError {
        case missingFile(path: String)
        case controlFileMissing(path: String)
        case extractionFailed(stderr: String, exitCode: Int)

        var errorDescription: String? {
            switch self {
            case .missingFile(let path):
                return "File does not exist at path: \(path)"
            case .controlFileMissing(let path):
                return "Control file does not exist at path: \(path)"
            case .extractionFailed(let stderr, let exitCode):
                if stderr.isEmpty {
                    return "dpkg-deb failed with exit code \(exitCode)."
                }
                return "dpkg-deb failed (exit \(exitCode)): \(stderr)"
            }
        }
    }

    static func extractAndParse(filePath: String, stagingDirectory: String)
        throws
        -> Control
    {
        do {
            return try extractAndParseInner(filePath: filePath, stagingDirectory: stagingDirectory)
        } catch let ServiceError.extractionFailed(stderr, exitCode) {
            // 读取阶段可能因 control.tar 权限异常（如 control 文件 0600 且属主 UID 不存在）
            // 导致 dpkg-deb 失败。这里自动重打包放宽 control 权限后重试一次，无需外部干预。
            NSLog("[Hoshu] dpkg-deb 提取失败，尝试自动修复 control 权限后重试：\(stderr)")
            if let fixed = try? DebControlPermissionRepair.repair(debPath: filePath) {
                defer { try? FileManager.default.removeItem(atPath: fixed) }
                do {
                    return try extractAndParseInner(filePath: fixed, stagingDirectory: stagingDirectory)
                } catch {
                    throw ServiceError.extractionFailed(
                        stderr: "已自动尝试修复 control 权限但仍失败：\(error.localizedDescription)\n原始错误：\(stderr)",
                        exitCode: exitCode
                    )
                }
            }
            throw ServiceError.extractionFailed(stderr: stderr, exitCode: exitCode)
        }
    }

    private static func extractAndParseInner(filePath: String, stagingDirectory: String)
        throws
        -> Control
    {
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw ServiceError.missingFile(path: filePath)
        }

        let extractionDir = try prepareExtractionDirectory(
            filePath: filePath,
            stagingDirectory: stagingDirectory
        )

        let result = AuxiliaryExecute.spawn(
            command: "/var/jb/usr/bin/dpkg-deb",
            args: ["-R", filePath, extractionDir],
            environment: [
                "PATH": prefixedEnvironmentPath().joined(separator: ":")
            ]
        )

        NSLog(
            "[Hoshu] Data extraction stderr: \(result.stderr), exit code: \(result.exitCode)"
        )

        guard result.exitCode == 0 else {
            throw ServiceError.extractionFailed(
                stderr: result.stderr,
                exitCode: result.exitCode
            )
        }

        NSLog(
            "[Hoshu] Successfully extracted \(URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent) to \(extractionDir)"
        )

        return try parseControlFile(extractionDir: extractionDir)
    }

    private static func prepareExtractionDirectory(
        filePath: String,
        stagingDirectory: String
    ) throws -> String {
        let fileURL = URL(fileURLWithPath: filePath)
        let filename = fileURL.deletingPathExtension().lastPathComponent
        let extractionDir = stagingDirectory + filename

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: extractionDir) {
            try fileManager.removeItem(atPath: extractionDir)
        }

        try fileManager.createDirectory(
            atPath: extractionDir,
            withIntermediateDirectories: true
        )

        return extractionDir
    }

    private static func prefixedEnvironmentPath() -> [String] {
        ProcessInfo
            .processInfo
            .environment["PATH"]?
            .components(separatedBy: ":")
            .compactMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .map { path in
                if path.hasPrefix("/var/jb/") {
                    return path
                }
                return "/var/jb/" + path
            }
            ?? []
    }

    private static func parseControlFile(extractionDir: String) throws
        -> Control
    {
        let controlFilePath = extractionDir + "/DEBIAN/control"
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: controlFilePath) else {
            throw ServiceError.controlFileMissing(path: controlFilePath)
        }

        let controlFileContents = try String(
            contentsOfFile: controlFilePath,
            encoding: .utf8
        )
        let lines = controlFileContents.components(separatedBy: .newlines)

        var fields: [String: String] = [:]
        var currentKey = ""
        var currentValue = ""

        for line in lines {
            if line.isEmpty { continue }

            if line.first == " " || line.first == "\t" {
                currentValue += "\n" + line.trimmingCharacters(in: .whitespaces)
                fields[currentKey] = currentValue
                continue
            }

            if !currentKey.isEmpty && !currentValue.isEmpty {
                fields[currentKey] = currentValue
                currentKey = ""
                currentValue = ""
            }

            let components = line.split(
                separator: ":",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            if components.count == 2 {
                currentKey = String(components[0]).trimmingCharacters(
                    in: .whitespaces
                )
                currentValue = String(components[1]).trimmingCharacters(
                    in: .whitespaces
                )
            }
        }

        if !currentKey.isEmpty && !currentValue.isEmpty {
            fields[currentKey] = currentValue
        }

        let package = fields["Package"] ?? ""
        let architecture = fields["Architecture"] ?? ""
        let maintainer = fields["Maintainer"] ?? ""

        let filename = URL(fileURLWithPath: extractionDir).lastPathComponent
        let isRootlessFilename = filename.lowercased().contains("arm64")
        let isRootlessArchitecture = architecture.lowercased().contains("arm64")
        let isDetectedAsRootless = isRootlessFilename || isRootlessArchitecture

        return Control(
            id: UUID(),
            package: package,
            name: fields["Name"] ?? package,
            version: fields["Version"] ?? "",
            architecture: architecture,
            packageDescription: fields["Description"] ?? "",
            maintainer: maintainer,
            author: fields["Author"] ?? maintainer,
            section: fields["Section"] ?? "",
            depends: fields["Depends"]?.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            } ?? [],
            conflicts: fields["Conflicts"]?.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            } ?? [],
            icon: fields["Icon"] ?? "",
            depiction: fields["Depiction"] ?? "",
            homepage: fields["Homepage"].flatMap { URL(string: $0) },
            installedSize: Int(fields["Installed-Size"] ?? "0") ?? 0,
            isDetectedAsRootless: isDetectedAsRootless
        )
    }
}
