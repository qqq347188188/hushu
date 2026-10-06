import AuxiliaryExecute
import Foundation

/// 将 .deb 内 control.tar.* 的权限自动放宽、属主改为 root，从而修复
/// 因 control 文件权限不足（如 0600 且属主 UID 不存在）导致 Hoshu 用
/// dpkg-deb 读取时失败的问题。修复范围完全在 Hoshu 内部，无需外部干预。
///
/// 原理与独立的 HoshuDebFixer 工具一致：重新打包 ar 归档，仅替换
/// control.tar.* 成员，把其内所有成员权限设为 0644、属主/组设为 0(root)。
enum DebControlPermissionRepair {
    enum RepairError: LocalizedError {
        case toolMissing(String)
        case arParse(String)
        case noControlMember
        case repairFailed(stderr: String, exitCode: Int)

        var errorDescription: String? {
            switch self {
            case .toolMissing(let t):
                return "修复 control 权限所需的工具不存在：\(t)"
            case .arParse(let m):
                return "解析 .deb 归档失败：\(m)"
            case .noControlMember:
                return "未找到 control.tar 成员，无需修复"
            case .repairFailed(let s, let c):
                return "control 权限修复失败（退出码 \(c)）：\(s)"
            }
        }
    }

    /// 修复 .deb 的 control 权限，返回修复后新 .deb 的临时路径（调用方负责清理）。
    /// 若无法修复（工具缺失 / 无 control 成员）则抛出。
    static func repair(debPath: String) throws -> String {
        let fm = FileManager.default
        let workDir = (debPath as NSString).deletingLastPathComponent
            + "/.hoshu_repair_\(UUID().uuidString)"
        try fm.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: workDir) }

        // 1. 解析 ar 归档，取出 control.tar.* 成员
        let members = try parseAR(at: debPath)
        guard let controlIdx = members.firstIndex(where: { $0.name.hasPrefix("control.tar") }) else {
            throw RepairError.noControlMember
        }
        let controlName = members[controlIdx].name
        let controlData = members[controlIdx].data
        let ext = (controlName as NSString).pathExtension.lowercased()

        // 2. 用 tar 解包 control 并重新打包（强制权限/属主）
        let tar = try locateTar()
        let ctrlExtract = workDir + "/ctrl"
        try fm.createDirectory(atPath: ctrlExtract, withIntermediateDirectories: true)
        let ctrlPath = workDir + "/control.orig"
        try controlData.write(to: URL(fileURLWithPath: ctrlPath))

        let xRes = AuxiliaryExecute.spawn(
            command: tar,
            args: ["-xf", ctrlPath, "-C", ctrlExtract],
            environment: prefixedEnvironment()
        )
        guard xRes.exitCode == 0 else {
            throw RepairError.repairFailed(stderr: xRes.stderr, exitCode: xRes.exitCode)
        }

        let fixedControlPath = workDir + "/control.fixed"
        var cargs = [String]()
        switch ext {
        case "gz": cargs.append("-z")
        case "xz": cargs.append("-J")
        case "zst": cargs.append("--zstd")
        case "bz2": cargs.append("-j")
        default: break
        }
        cargs += [
            "-cf", fixedControlPath, "-C", ctrlExtract,
            "--no-same-permissions", "--mode=0644",
            "--owner=0", "--group=0", "--numeric-owner", ".",
        ]
        let cRes = AuxiliaryExecute.spawn(
            command: tar,
            args: cargs,
            environment: prefixedEnvironment()
        )
        guard cRes.exitCode == 0 else {
            throw RepairError.repairFailed(stderr: cRes.stderr, exitCode: cRes.exitCode)
        }
        let fixedControlData = try Data(contentsOf: URL(fileURLWithPath: fixedControlPath))

        // 3. 重新组装 ar（保持 debian-binary / control / data 顺序，data 原样保留）
        var rebuilt = members
        rebuilt[controlIdx] = (controlName, fixedControlData)
        let ordered = rebuilt.sorted { orderIndex($0.name) < orderIndex($1.name) }
        let fixedDeb = debPath + ".fixed.deb"
        if fm.fileExists(atPath: fixedDeb) { try fm.removeItem(atPath: fixedDeb) }
        try buildAR(members: ordered).write(to: URL(fileURLWithPath: fixedDeb))
        return fixedDeb
    }

    // MARK: - ar 解析 / 生成（纯 Swift，无外部依赖）

    private static func parseAR(at path: String) throws -> [(name: String, data: Data)] {
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        guard raw.count >= 8,
              raw.subdata(in: 0 ..< 8) == Data("!<arch>\n".utf8) else {
            throw RepairError.arParse("不是有效的 .deb（缺少 ar 签名）")
        }
        var members: [(String, Data)] = []
        var off = 8
        while off + 60 <= raw.count {
            let header = raw.subdata(in: off ..< off + 60)
            let nameRaw = String(data: header.subdata(in: 0 ..< 16), encoding: .ascii) ?? ""
            let name = nameRaw.split(separator: "/").first.map(String.init)
                ?? nameRaw.trimmingCharacters(in: .whitespaces)
            let sizeStr = String(data: header.subdata(in: 48 ..< 58), encoding: .ascii) ?? ""
            guard let size = Int(sizeStr.trimmingCharacters(in: .whitespaces), radix: 10) else {
                throw RepairError.arParse("成员大小解析失败")
            }
            let start = off + 60
            let end = start + size
            guard end <= raw.count else { throw RepairError.arParse("成员数据越界") }
            members.append((name, raw.subdata(in: start ..< end)))
            off = end + (size & 1)
        }
        return members
    }

    private static func buildAR(members: [(name: String, data: Data)]) -> Data {
        var out = Data("!<arch>\n".utf8)
        for (name, data) in members {
            let nameField = (name + "/").padding(toLength: 16, withPad: " ", startingAt: 0)
            let mtimeField = "0".padding(toLength: 12, withPad: " ", startingAt: 0)
            let uidField = "0".padding(toLength: 12, withPad: " ", startingAt: 0)
            let modeField = "100644".padding(toLength: 8, withPad: " ", startingAt: 0)
            let sizeField = String(data.count).padding(toLength: 10, withPad: " ", startingAt: 0)
            let header = nameField + mtimeField + uidField + modeField + sizeField + "`\n"
            out.append(header.data(using: .ascii)!)
            out.append(data)
            if data.count & 1 == 1 { out.append(contentsOf: [UInt8(0x0A)]) }
        }
        return out
    }

    private static func orderIndex(_ name: String) -> Int {
        if name == "debian-binary" { return 0 }
        if name.hasPrefix("control.tar") { return 1 }
        if name.hasPrefix("data.tar") { return 2 }
        return 3
    }

    // MARK: - 工具定位

    private static func locateTar() throws -> String {
        let candidates = [
            "/var/jb/usr/bin/tar",
            "/var/jb/bin/tar",
            "/usr/bin/tar",
            "/bin/tar",
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return c
        }
        throw RepairError.toolMissing("tar（请确认越狱环境已安装 tar）")
    }

    private static func prefixedEnvironment() -> [String: String] {
        let paths = ProcessInfo.processInfo.environment["PATH"]?
            .components(separatedBy: ":")
            .compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.hasPrefix("/var/jb/") ? $0 : "/var/jb/" + $0 }
            ?? []
        return ["PATH": paths.joined(separator: ":")]
    }
}
