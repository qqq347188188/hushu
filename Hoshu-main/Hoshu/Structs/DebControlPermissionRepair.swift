import AuxiliaryExecute
import Foundation

/// 在转换前自动放宽 .deb 内 DEBIAN 脚本（control/postinst/postrm 等）的权限，
/// 修复因这些文件权限异常（如 0600、属主 UID 不存在）导致 rootless-patcher 读取/
/// 改写 DEBIAN 脚本时 "you don't have permission to view it" 的问题。
///
/// 实现上完全依赖设备上必然存在的 `dpkg-deb`（Hoshu 提取、rootless-patcher 都在用它）：
///   1. dpkg-deb -R 解包到临时目录；
///   2. 对 DEBIAN/ 下所有文件 chmod 0777（可读可写可执行，rootless-patcher 需要写 control）；
///   3. dpkg-deb -b 重新打包为合法 .deb。
/// 这比手写 ar/tar/gzip 重建可靠得多，产出的一定是可被 dpkg-deb 解析的 deb。
enum DebControlPermissionRepair {
    enum RepairError: LocalizedError {
        case dpkgMissing
        case extractFailed(stderr: String, exitCode: Int)
        case repackFailed(stderr: String, exitCode: Int)
        case noDebianDir

        var errorDescription: String? {
            switch self {
            case .dpkgMissing:
                return "未找到 dpkg-deb（请确认越狱环境已安装 dpkg）"
            case .extractFailed(let s, let c):
                return "解包 .deb 失败（退出码 \(c)）：\(s)"
            case .repackFailed(let s, let c):
                return "重新打包 .deb 失败（退出码 \(c)）：\(s)"
            case .noDebianDir:
                return "解包后未找到 DEBIAN 目录，无法修复"
            }
        }
    }

    /// 修复 .deb 的 control 权限，返回修复后新 .deb 的路径（调用方负责清理）。
    static func repair(debPath: String) throws -> String {
        let dpkg = "/var/jb/usr/bin/dpkg-deb"
        guard FileManager.default.fileExists(atPath: dpkg) else {
            throw RepairError.dpkgMissing
        }

        let fm = FileManager.default
        let workDir = NSTemporaryDirectory() + "hoshu_repair_\(UUID().uuidString)"
        let extractDir = workDir + "/extracted"
        try fm.createDirectory(atPath: extractDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: workDir) }

        let env = ["PATH": prefixedEnvironmentPath().joined(separator: ":")]

        // 1) 解包（dpkg-deb 只需读取外层 .deb，不依赖内部成员权限，故一定能解包成功）
        let xRes = AuxiliaryExecute.spawn(
            command: dpkg,
            args: ["-R", debPath, extractDir],
            environment: env
        )
        guard xRes.exitCode == 0 else {
            throw RepairError.extractFailed(stderr: xRes.stderr, exitCode: xRes.exitCode)
        }

        // 2) 放宽 DEBIAN/ 下所有文件权限为 0777
        let debianDir = extractDir + "/DEBIAN"
        guard fm.fileExists(atPath: debianDir) else {
            throw RepairError.noDebianDir
        }
        let entries = try fm.contentsOfDirectory(atPath: debianDir)
        for entry in entries {
            let path = debianDir + "/" + entry
            try fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: path)
        }

        // 3) 重新打包为合法 .deb
        let fixedDeb = debPath + ".fixed.deb"
        if fm.fileExists(atPath: fixedDeb) {
            try? fm.removeItem(atPath: fixedDeb)
        }
        let bRes = AuxiliaryExecute.spawn(
            command: dpkg,
            args: ["-b", extractDir, fixedDeb],
            environment: env
        )
        guard bRes.exitCode == 0 else {
            throw RepairError.repackFailed(stderr: bRes.stderr, exitCode: bRes.exitCode)
        }
        return fixedDeb
    }

    private static func prefixedEnvironmentPath() -> [String] {
        ProcessInfo
            .processInfo
            .environment["PATH"]?
            .components(separatedBy: ":")
            .compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { path in
                if path.hasPrefix("/var/jb/") { return path }
                return "/var/jb/" + path
            }
            ?? []
    }
}
