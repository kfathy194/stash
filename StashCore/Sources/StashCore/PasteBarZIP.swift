import Foundation
import Compression

// Read entries in memory; never extract archive paths onto the filesystem.
struct PasteBarZIP {
    struct Entry { let name: String; let offset: Int; let size: Int; let compressedSize: Int; let method: Int; let crc: UInt32 }
    let data: Data
    let entries: [String: Entry]
    init(url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= 512 * 1024 * 1024 else { throw PasteBarImportError.archiveLimit }
        let data = try Data(contentsOf: url, options: [])
        var directory: [String: Entry] = [:]
        func integer(_ p: Int, _ bytes: Int) throws -> Int {
            guard p >= 0, p <= data.count - bytes else { throw PasteBarImportError.invalidBackup }
            return (0..<bytes).reduce(0) { $0 | Int(data[p + $1]) << (8 * $1) }
        }
        guard data.count >= 22 else { throw PasteBarImportError.invalidBackup }
        let end = try (max(0, data.count - 65557)...data.count - 22).reversed().first { p in
            try integer(p, 4) == 0x06054b50 && p + 22 + integer(p + 20, 2) == data.count
        }
        guard let end, try integer(end + 4, 2) == 0, try integer(end + 6, 2) == 0 else { throw PasteBarImportError.invalidBackup }
        let count = try integer(end + 10, 2), directorySize = try integer(end + 12, 4), start = try integer(end + 16, 4)
        guard count < 65535, count == (try integer(end + 8, 2)), start + directorySize == end else { throw PasteBarImportError.invalidBackup }
        var p = start, total = 0
        for _ in 0..<count {
            guard try integer(p, 4) == 0x02014b50 else { throw PasteBarImportError.invalidBackup }
            let flags = try integer(p + 8, 2), method = try integer(p + 10, 2)
            let packed = try integer(p + 20, 4), size = try integer(p + 24, 4)
            let nameLength = try integer(p + 28, 2), extraLength = try integer(p + 30, 2), commentLength = try integer(p + 32, 2)
            let offset = try integer(p + 42, 4)
            guard flags & 1 == 0, method == 0 || method == 8, try integer(p + 34, 2) == 0,
                  size <= 256 * 1024 * 1024, packed <= 512 * 1024 * 1024,
                  p + 46 + nameLength + extraLength + commentLength <= end,
                  let rawName = String(data: data.subdata(in: p + 46..<p + 46 + nameLength), encoding: .utf8) else { throw PasteBarImportError.invalidBackup }
            let name = rawName.replacingOccurrences(of: "\\", with: "/")
            guard !name.hasPrefix("/"), !name.contains(":"), !name.contains("\0"), !name.components(separatedBy: "/").contains(".."),
                  !name.components(separatedBy: "/").contains("."), directory[name] == nil else { throw PasteBarImportError.invalidBackup }
            let mode = try integer(p + 38, 4) >> 16
            guard mode & 0xF000 != 0xA000 else { throw PasteBarImportError.invalidBackup }
            guard try integer(offset, 4) == 0x04034b50, try integer(offset + 8, 2) == method else { throw PasteBarImportError.invalidBackup }
            let localNameLength = try integer(offset + 26, 2), localExtraLength = try integer(offset + 28, 2)
            let body = offset + 30 + localNameLength + localExtraLength
            guard body <= start, packed <= start - body,
                  localNameLength == nameLength,
                  data.subdata(in: offset + 30..<offset + 30 + localNameLength) == data.subdata(in: p + 46..<p + 46 + nameLength) else { throw PasteBarImportError.invalidBackup }
            total += size
            guard total <= 1024 * 1024 * 1024 else { throw PasteBarImportError.archiveLimit }
            directory[name] = Entry(name: name, offset: body, size: size, compressedSize: packed, method: method, crc: UInt32(try integer(p + 16, 4)))
            p += 46 + nameLength + extraLength + commentLength
        }
        guard p == end else { throw PasteBarImportError.invalidBackup }
        self.data = data
        entries = directory
    }
    func contents(_ name: String) throws -> Data? {
        guard let entry = entries[name] else { return nil }
        let packed = data.subdata(in: entry.offset..<entry.offset + entry.compressedSize)
        let result: Data
        if entry.method == 0 { result = packed }
        else {
            guard !packed.isEmpty else { throw PasteBarImportError.invalidBackup }
            var output = Data(count: entry.size + 1)
            let decoded = output.withUnsafeMutableBytes { destination in
                packed.withUnsafeBytes { source in
                    compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, entry.size + 1,
                                              source.bindMemory(to: UInt8.self).baseAddress!, packed.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard decoded == entry.size else { throw PasteBarImportError.invalidBackup }
            result = output.prefix(decoded)
        }
        guard result.count == entry.size else { throw PasteBarImportError.invalidBackup }
        var crc: UInt32 = 0xFFFFFFFF
        for byte in result {
            crc = (crc >> 8) ^ Self.crcTable[Int((crc ^ UInt32(byte)) & 255)]
        }
        guard ~crc == entry.crc else { throw PasteBarImportError.invalidBackup }
        return result
    }
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB88320 : 0) }
        return crc
    }

}
