import Foundation

/// 16 kHz mono 16-bit WAV, kirjutatakse jooksvalt (päist uuendatakse aeg-ajalt, et katkestus ei rikuks faili).
public final class WavWriter {
    private let fh: FileHandle
    public private(set) var dataBytes: Int64 = 0

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: WavWriter.header(0))
        fh = try FileHandle(forUpdating: url)
        try fh.seekToEnd()
    }

    public func write(_ samples: ArraySlice<Int16>) {
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) } // little-endian (arm64)
        try? fh.write(contentsOf: data)
        dataBytes += Int64(data.count)
    }

    public func updateHeader() {
        guard let pos = try? fh.offset() else { return }
        try? fh.seek(toOffset: 0)
        try? fh.write(contentsOf: WavWriter.header(dataBytes))
        try? fh.seek(toOffset: pos)
    }

    public func close() {
        updateHeader()
        try? fh.close()
    }

    public static func header(_ dataLen: Int64) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(truncatingIfNeeded: 36 + dataLen))
        d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(truncatingIfNeeded: dataLen))
        return d
    }

    /// Kui äpp katkes salvestamise ajal, paranda päise pikkused.
    public static func repair(_ url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value, size >= 44,
              let fh = try? FileHandle(forUpdating: url) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: 40)
        guard let b = try? fh.read(upToCount: 4), b.count == 4 else { return }
        let stored = Int64(b.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        if stored != size - 44 {
            try? fh.seek(toOffset: 0)
            try? fh.write(contentsOf: header(size - 44))
        }
    }
}
