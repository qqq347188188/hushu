import Foundation
import Compression

// MARK: - ar 归档解析/重建

struct ArMember {
    let name: String
    let data: Data
}

func parseAr(_ data: Data) throws -> [ArMember] {
    guard data.prefix(8) == Data("!<arch>\n".utf8) else {
        throw NSError(domain: "DebFixer", code: 100,
                      userInfo: [NSLocalizedDescriptionKey: "不是有效的 .deb（缺少 ar 签名）"])
    }
    var members: [ArMember] = []
    var offset = 8
    while offset + 60 <= data.count {
        let header = data.subdata(in: offset..<offset + 60)
        let name = String(data: header.subdata(in: 0..<16), encoding: .ascii)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sizeStr = String(data: header.subdata(in: 48..<58), encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        guard let size = Int(sizeStr) else {
            throw NSError(domain: "DebFixer", code: 101,
                          userInfo: [NSLocalizedDescriptionKey: "ar 头解析失败"])
        }
        let dataStart = offset + 60
        guard dataStart + size <= data.count else {
            throw NSError(domain: "DebFixer", code: 102,
                          userInfo: [NSLocalizedDescriptionKey: "ar 成员数据越界"])
        }
        let content = data.subdata(in: dataStart..<dataStart + size)
        members.append(ArMember(name: name, data: content))
        offset = dataStart + size
        if size % 2 == 1 { offset += 1 }
    }
    return members
}

func buildAr(_ members: [ArMember]) -> Data {
    var out = Data("!<arch>\n".utf8)
    for m in members {
        var nameField = m.name + "/"
        if nameField.count < 16 {
            nameField += String(repeating: " ", count: 16 - nameField.count)
        } else {
            nameField = String(nameField.prefix(16))
        }
        let modeField = String(format: "%-8s", "100644")
        let sizeField = String(format: "%-10d", m.data.count)
        let header = "\(nameField)\(String(repeating: " ", count: 12))\(String(repeating: " ", count: 12))\(modeField)\(sizeField)`\n"
        out.append(Data(header.utf8))
        out.append(m.data)
        if m.data.count % 2 == 1 { out.append(0) }
    }
    return out
}

// MARK: - gzip

func gzipDecompress(_ data: Data) -> Data? {
    let dstSize = max(data.count * 8, 65536)
    var dst = Data(count: dstSize)
    let written = data.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) -> Int in
        let src = srcRaw.bindMemory(to: UInt8.self).baseAddress!
        return dst.withUnsafeMutableBytes { (dstRaw: UnsafeMutableRawBufferPointer) -> Int in
            let d = dstRaw.bindMemory(to: UInt8.self).baseAddress!
            return Int(compression_decode_buffer(d, dstSize, src, data.count, nil, COMPRESSION_GZIP))
        }
    }
    guard written > 0 else { return nil }
    return dst.subdata(in: 0..<written)
}

func gzipCompress(_ data: Data) -> Data? {
    let dstSize = data.count * 2 + 8192
    var dst = Data(count: dstSize)
    let written = data.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) -> Int in
        let src = srcRaw.bindMemory(to: UInt8.self).baseAddress!
        return dst.withUnsafeMutableBytes { (dstRaw: UnsafeMutableRawBufferPointer) -> Int in
            let d = dstRaw.bindMemory(to: UInt8.self).baseAddress!
            return Int(compression_encode_buffer(d, dstSize, src, data.count, nil, COMPRESSION_GZIP))
        }
    }
    guard written > 0 else { return nil }
    return dst.subdata(in: 0..<written)
}

// MARK: - tar 解析/重建 (ustar)

struct TarEntry {
    let name: String
    var mode: Int
    var uid: Int
    var gid: Int
    let size: Int
    let typeflag: UInt8
    let data: Data
}

func parseTar(_ data: Data) throws -> [TarEntry] {
    var entries: [TarEntry] = []
    var offset = 0
    while offset + 512 <= data.count {
        let header = data.subdata(in: offset..<offset + 512)
        let name = String(data: header.subdata(in: 0..<100), encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
        if name.isEmpty { break }
        let mode = Int(String(data: header.subdata(in: 100..<108), encoding: .ascii)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")) ?? "0", radix: 8) ?? 0
        let uid = Int(String(data: header.subdata(in: 108..<116), encoding: .ascii)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")) ?? "0", radix: 8) ?? 0
        let gid = Int(String(data: header.subdata(in: 116..<124), encoding: .ascii)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")) ?? "0", radix: 8) ?? 0
        let size = Int(String(data: header.subdata(in: 124..<136), encoding: .ascii)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")) ?? "0", radix: 8) ?? 0
        let typeflag = header[156]
        let dataStart = offset + 512
        let dataEnd = dataStart + ((size + 511) / 512) * 512
        guard dataEnd <= data.count else { break }
        let fileData = data.subdata(in: dataStart..<dataStart + size)
        entries.append(TarEntry(name: name, mode: mode, uid: uid, gid: gid,
                                size: size, typeflag: typeflag, data: fileData))
        offset = dataEnd
    }
    return entries
}

func writeOctal(_ h: inout [UInt8], at: Int, value: Int, width: Int) {
    let s = String(format: "%0*o", width - 1, value)
    let u = [UInt8](s.utf8)
    for i in 0..<u.count { h[at + i] = u[i] }
    h[at + u.count] = 0
}

func buildTar(_ entries: [TarEntry]) -> Data {
    var out = Data()
    for e in entries {
        var h = [UInt8](repeating: 0, count: 512)
        let nameU = [UInt8](e.name.utf8)
        for i in 0..<min(100, nameU.count) { h[i] = nameU[i] }
        writeOctal(&h, at: 100, value: e.mode | 0o644, width: 8)
        writeOctal(&h, at: 108, value: e.uid, width: 8)
        writeOctal(&h, at: 116, value: e.gid, width: 8)
        writeOctal(&h, at: 124, value: e.size, width: 12)
        writeOctal(&h, at: 136, value: 0, width: 12)
        h[156] = e.typeflag
        let magic: [UInt8] = [UInt8]("ustar".utf8) + [0x00, 0x30, 0x30] // "ustar\0" + "00"
        for i in 0..<8 { h[257 + i] = magic[i] }
        for i in 148..<156 { h[i] = 0x20 }
        var sum = 0
        for b in h { sum += Int(b) }
        let chk = String(format: "%06o", sum)
        let chkU = [UInt8](chk.utf8)
        for i in 0..<6 { h[148 + i] = chkU[i] }
        h[154] = 0
        h[155] = 0x20
        out.append(Data(h))
        out.append(e.data)
        let pad = (512 - (e.size % 512)) % 512
        if pad > 0 { out.append(Data(count: pad)) }
    }
    out.append(Data(count: 1024)) // 结束零块
    return out
}

// MARK: - 主修复逻辑

func repairDeb(_ input: Data) throws -> Data {
    var members = try parseAr(input)
    for i in members.indices {
        let n = members[i].name
        if n == "control.tar.gz" || n.hasSuffix("control.tar.gz") {
            guard let tar = gzipDecompress(members[i].data) else {
                throw NSError(domain: "DebFixer", code: 200,
                              userInfo: [NSLocalizedDescriptionKey: "control.tar.gz 解压失败"])
            }
            var entries = try parseTar(tar)
            for j in entries.indices {
                entries[j].mode = entries[j].mode | 0o644
                entries[j].uid = 0
                entries[j].gid = 0
            }
            let newTar = buildTar(entries)
            guard let newGz = gzipCompress(newTar) else {
                throw NSError(domain: "DebFixer", code: 201,
                              userInfo: [NSLocalizedDescriptionKey: "control.tar.gz 压缩失败"])
            }
            members[i].data = newGz
        }
    }
    return buildAr(members)
}
