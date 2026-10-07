import AuxiliaryExecute
import Foundation
import zlib

/// 将 .deb 内 control.tar.* 的权限自动放宽（0777、属主 root），从而修复
/// 因 DEBIAN 下 control/postinst/postrm 等文件权限不足导致的问题：
/// - Hoshu 用 dpkg-deb 读取 control 时失败；
/// - rootless-patcher 转换时无法读取/改写 DEBIAN 脚本
///   （patcher 需要写权限，故统一放宽为 0777 而非 0644）。
///
/// .gz / 未压缩 tar 走纯 Swift 路径（zlib + tar 头字节修补），
/// 不依赖任何外部工具；.xz / .zst / .bz2 回退用系统 tar 重新打包。
enum DebControlPermissionRepair {
    enum RepairError: LocalizedError {
        case toolMissing(String)
        case arParse(String)
        case noControlMember
        case repairFailed(stderr: String, exitCode: Int)
        case gunzipFailed
        case gzipFailed
        case tarParse(String)

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
            case .gunzipFailed:
                return "control.tar.gz 解压失败"
            case .gzipFailed:
                return "control.tar.gz 重新压缩失败"
            case .tarParse(let m):
                return "解析 control.tar 失败：\(m)"
            }
        }
    }

    /// 修复 .deb 的 control 权限，返回修复后新 .deb 的路径（调用方负责清理）。
    static func repair(debPath: String) throws -> String {
        let fm = FileManager.default

        var members = try parseAR(at: debPath)
        guard let controlIdx = members.firstIndex(where: { $0.name.hasPrefix("control.tar") }) else {
            throw RepairError.noControlMember
        }
        let controlName = members[controlIdx].name
        let ext = (controlName as NSString).pathExtension.lowercased()
        let isPlainTar = controlName.lowercased().hasSuffix(".tar")

        let fixedControlData: Data
        if ext == "gz" || isPlainTar {
            // 纯 Swift：zlib 解压 + tar 头权限修补 + 重新压缩，无外部依赖
            var tarData = ext == "gz" ? try gunzip(members[controlIdx].data) : members[controlIdx].data
            tarData = try patchTarPermissions(in: tarData)
            fixedControlData = ext == "gz" ? try gzip(tarData) : tarData
        } else {
            // xz/zst/bz2 等：回退系统 tar
            fixedControlData = try rebuildControlWithTar(
                controlData: members[controlIdx].data,
                compression: ext
            )
        }

        members[controlIdx] = (controlName, fixedControlData)
        let ordered = members.sorted { orderIndex($0.name) < orderIndex($1.name) }
        let fixedDeb = debPath + ".fixed.deb"
        if fm.fileExists(atPath: fixedDeb) { try? fm.removeItem(atPath: fixedDeb) }
        try buildAR(members: ordered).write(to: URL(fileURLWithPath: fixedDeb))
        return fixedDeb
    }

    // MARK: - tar 头权限修补（纯 Swift，无外部依赖）

    /// 遍历 tar 所有成员，把 mode 改为 0777、uid/gid 改为 0，并重写校验和。
    private static func patchTarPermissions(in raw: Data) throws -> Data {
        var bytes = [UInt8](raw)
        var offset = 0

        while offset + 512 <= bytes.count {
            let header = Array(bytes[offset ..< offset + 512])
            if header.isEmpty || header.allSatisfy({ $0 == 0 }) { break }

            // 解析 size 字段（offset+124，12 字节八进制）
            var size = 0
            var sawDigit = false
            var sizeValid = true
            for i in 124 ..< 136 {
                let b = header[i]
                if b == 0 || b == 0x20 {
                    if sawDigit { break }
                    continue
                }
                guard (0x30 ... 0x37).contains(b) else {
                    sizeValid = false
                    break
                }
                size = size * 8 + Int(b - 0x30)
                sawDigit = true
            }
            guard sizeValid, sawDigit else {
                throw RepairError.tarParse("成员大小字段解析失败")
            }

            writeTarField(&bytes, offset: offset + 100, digits: "0000777") // mode
            writeTarField(&bytes, offset: offset + 108, digits: "0000000") // uid -> root
            writeTarField(&bytes, offset: offset + 116, digits: "0000000") // gid -> root

            // 重算 checksum：148..<156 按空格计入
            var sum = 0
            for i in 0 ..< 512 {
                sum += (i >= 148 && i < 156) ? Int(0x20) : Int(bytes[offset + i])
            }
            var octal = String(sum, radix: 8)
            if octal.count > 6 { octal = String(octal.suffix(6)) }
            while octal.count < 6 { octal = "0" + octal }
            var checksum = Array(octal.utf8)
            checksum.append(0)
            checksum.append(0x20)
            for (i, b) in checksum.enumerated() where offset + 148 + i < bytes.count {
                bytes[offset + 148 + i] = b
            }

            offset += 512 + ((size + 511) / 512) * 512
        }
        return Data(bytes)
    }

    /// 写入 8 字节 tar 字段：7 位八进制数字 + '\0'
    private static func writeTarField(_ bytes: inout [UInt8], offset: Int, digits: String) {
        var field = Array(digits.utf8)
        field.append(0)
        for (i, b) in field.enumerated() where offset + i < bytes.count {
            bytes[offset + i] = b
        }
    }

    // MARK: - zlib gzip（纯 Swift）

    private static func gunzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        let initStatus = inflateInit2_(
            &stream, 47, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else { throw RepairError.gunzipFailed }
        defer { inflateEnd(&stream) }

        var input = [UInt8](data)
        var output = [UInt8]()
        let chunkSize = 262144
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var status: Int32 = Z_OK

        input.withUnsafeMutableBufferPointer { inPtr in
            stream.next_in = inPtr.baseAddress
            stream.avail_in = uInt(inPtr.count)
            repeat {
                status = chunk.withUnsafeMutableBufferPointer { outPtr -> Int32 in
                    stream.next_out = outPtr.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    let result = inflate(&stream, Z_NO_FLUSH)
                    output.append(contentsOf: outPtr.prefix(chunkSize - Int(stream.avail_out)))
                    return result
                }
            } while status == Z_OK
        }

        guard status == Z_STREAM_END else { throw RepairError.gunzipFailed }
        return Data(output)
    }

    private static func gzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        let initStatus = deflateInit2_(
            &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8,
            Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else { throw RepairError.gzipFailed }
        defer { deflateEnd(&stream) }

        var input = [UInt8](data)
        var output = [UInt8]()
        let chunkSize = 262144
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var status: Int32 = Z_OK

        input.withUnsafeMutableBufferPointer { inPtr in
            stream.next_in = inPtr.baseAddress
            stream.avail_in = uInt(inPtr.count)
            repeat {
                status = chunk.withUnsafeMutableBufferPointer { outPtr -> Int32 in
                    stream.next_out = outPtr.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    let result = deflate(&stream, Z_FINISH)
                    output.append(contentsOf: outPtr.prefix(chunkSize - Int(stream.avail_out)))
                    return result
                }
            } while status == Z_OK
        }

        guard status == Z_STREAM_END else { throw RepairError.gzipFailed }
        return Data(output)
    }

    // MARK: - 系统 tar 回退（xz / zst / bz2 压缩的 control.tar）

    private static func rebuildControlWithTar(controlData: Data, compression: String) throws -> Data {
        let fm = FileManager.default
        let workDir = NSTemporaryDirectory() + "hoshu_repair_\(UUID().uuidString)"
        try fm.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: workDir) }

        let tar = try locateTar()
        let ctrlExtract = workDir + "/ctrl"
        try fm.createDirectory(atPath: ctrlExtract, withIntermediateDirectories: true)
        let ctrlPath = workDir + "/control.orig"
        try controlData.write(to: URL(fileURLWithPath: ctrlPath))

        var xflags = [String]()
        switch compression {
        case "gz": xflags.append("-z")
        case "xz": xflags.append("-J")
        case "zst": xflags.append("--zstd")
        case "bz2": xflags.append("-j")
        default: break
        }
        let xRes = AuxiliaryExecute.spawn(
            command: tar,
            args: xflags + ["-xf", ctrlPath, "-C", ctrlExtract],
            environment: prefixedEnvironment()
        )
        guard xRes.exitCode == 0 else {
            throw RepairError.repairFailed(stderr: xRes.stderr, exitCode: xRes.exitCode)
        }

        let fixedControlPath = workDir + "/control.fixed"
        var cargs = [String]()
        switch compression {
        case "gz": cargs.append("-z")
        case "xz": cargs.append("-J")
        case "zst": cargs.append("--zstd")
        case "bz2": cargs.append("-j")
        default: break
        }
        cargs += [
            "-cf", fixedControlPath, "-C", ctrlExtract,
            "--no-same-permissions", "--mode=0777",
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
        return try Data(contentsOf: URL(fileURLWithPath: fixedControlPath))
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

    // MARK: - 工具定位（仅 xz/zst/bz2 回退路径使用）

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
