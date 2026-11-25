import Foundation

// MARK: - Errors

enum AppError: LocalizedError {
    case io(String)
    case cancelled
    case notConnected(String)

    var errorDescription: String? {
        switch self {
        case .io(let m): return m
        case .cancelled: return "Cancelled"
        case .notConnected(let p): return "Destination not connected: \(p)"
        }
    }
}

func errnoText() -> String { String(cString: strerror(errno)) }

// MARK: - Cancel flag / throttle

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private var last: CFAbsoluteTime = 0
    private let interval: CFAbsoluteTime
    init(interval: CFAbsoluteTime) { self.interval = interval }
    func allow(force: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        if force || now - last >= interval { last = now; return true }
        return false
    }
}

// MARK: - Formatting helpers

func dateFormatter(_ format: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = format
    return f
}

func byteText(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

func cleanName(_ s: String) -> String {
    s.replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "-")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func relPath(_ u: URL, root rootPath: String) -> String {
    let p = u.standardizedFileURL.path
    if p.hasPrefix(rootPath + "/") { return String(p.dropFirst(rootPath.count + 1)) }
    let rp = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().path
    let pp = u.resolvingSymlinksInPath().path
    if pp.hasPrefix(rp + "/") { return String(pp.dropFirst(rp.count + 1)) }
    return u.lastPathComponent
}

/// ~/Library/Application Support/BCKUP (moves the old "Amanin" folder over once, keeping the catalog and Google login).
func appSupportDir() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("BCKUP", isDirectory: true)
    let old = base.appendingPathComponent("Amanin", isDirectory: true)
    let fm = FileManager.default
    if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: old.path) {
        try? fm.moveItem(at: old, to: dir)
    }
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func freeSpace(atPath path: String) -> Int64? {
    let u = URL(fileURLWithPath: path)
    let rv = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
    if let v = rv?.volumeAvailableCapacityForImportantUsage, v > 0 { return v }
    if let v = rv?.volumeAvailableCapacity { return Int64(v) }
    return nil
}

func totalSpace(atPath path: String) -> Int64? {
    let rv = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeTotalCapacityKey])
    return rv?.volumeTotalCapacity.map(Int64.init)
}

func volumeName(forPath path: String) -> String {
    let u = URL(fileURLWithPath: path)
    if let n = try? u.resourceValues(forKeys: [.volumeNameKey]).volumeName { return n }
    return u.lastPathComponent
}

// MARK: - XXH64 (streaming, xxHash 64-bit)

struct XXH64 {
    private static let p1: UInt64 = 0x9E37_79B1_85EB_CA87
    private static let p2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
    private static let p3: UInt64 = 0x1656_67B1_9E37_79F9
    private static let p4: UInt64 = 0x85EB_CA77_C2B2_AE63
    private static let p5: UInt64 = 0x27D4_EB2F_1656_67C5

    private let seed: UInt64
    private var v1: UInt64, v2: UInt64, v3: UInt64, v4: UInt64
    private var total: UInt64 = 0
    private var mem: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    private var memSize = 0

    init(seed: UInt64 = 0) {
        self.seed = seed
        v1 = seed &+ XXH64.p1 &+ XXH64.p2
        v2 = seed &+ XXH64.p2
        v3 = seed
        v4 = seed &- XXH64.p1
    }

    @inline(__always) private static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 {
        (x << r) | (x >> (64 &- r))
    }

    @inline(__always) private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        var a = acc &+ (input &* p2)
        a = rotl(a, 31)
        return a &* p1
    }

    @inline(__always) private static func mergeRound(_ acc: UInt64, _ val: UInt64) -> UInt64 {
        var a = acc ^ round(0, val)
        a = a &* p1 &+ p4
        return a
    }

    private mutating func consumeMem() {
        v1 = XXH64.round(v1, UInt64(littleEndian: mem.0))
        v2 = XXH64.round(v2, UInt64(littleEndian: mem.1))
        v3 = XXH64.round(v3, UInt64(littleEndian: mem.2))
        v4 = XXH64.round(v4, UInt64(littleEndian: mem.3))
    }

    mutating func update(_ data: UnsafeRawBufferPointer) {
        guard let base = data.baseAddress, data.count > 0 else { return }
        let len = data.count
        total &+= UInt64(len)
        let filled = memSize

        if filled + len < 32 {
            withUnsafeMutableBytes(of: &mem) { m in
                m.baseAddress!.advanced(by: filled).copyMemory(from: base, byteCount: len)
            }
            memSize = filled + len
            return
        }

        var p = 0
        if filled > 0 {
            let fill = 32 - filled
            withUnsafeMutableBytes(of: &mem) { m in
                m.baseAddress!.advanced(by: filled).copyMemory(from: base, byteCount: fill)
            }
            consumeMem()
            p = fill
            memSize = 0
        }

        var a = v1, b = v2, c = v3, d = v4
        while p + 32 <= len {
            let ptr = base.advanced(by: p)
            a = XXH64.round(a, UInt64(littleEndian: ptr.loadUnaligned(fromByteOffset: 0, as: UInt64.self)))
            b = XXH64.round(b, UInt64(littleEndian: ptr.loadUnaligned(fromByteOffset: 8, as: UInt64.self)))
            c = XXH64.round(c, UInt64(littleEndian: ptr.loadUnaligned(fromByteOffset: 16, as: UInt64.self)))
            d = XXH64.round(d, UInt64(littleEndian: ptr.loadUnaligned(fromByteOffset: 24, as: UInt64.self)))
            p += 32
        }
        v1 = a; v2 = b; v3 = c; v4 = d

        if p < len {
            let rest = len - p
            withUnsafeMutableBytes(of: &mem) { m in
                m.baseAddress!.copyMemory(from: base.advanced(by: p), byteCount: rest)
            }
            memSize = rest
        }
    }

    func digest() -> UInt64 {
        var h: UInt64
        if total >= 32 {
            h = XXH64.rotl(v1, 1) &+ XXH64.rotl(v2, 7) &+ XXH64.rotl(v3, 12) &+ XXH64.rotl(v4, 18)
            h = XXH64.mergeRound(h, v1)
            h = XXH64.mergeRound(h, v2)
            h = XXH64.mergeRound(h, v3)
            h = XXH64.mergeRound(h, v4)
        } else {
            h = seed &+ XXH64.p5
        }
        h &+= total

        var m = mem
        let n = memSize
        withUnsafeBytes(of: &m) { raw in
            var i = 0
            while i + 8 <= n {
                let k = XXH64.round(0, UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: UInt64.self)))
                h ^= k
                h = XXH64.rotl(h, 27) &* XXH64.p1 &+ XXH64.p4
                i += 8
            }
            if i + 4 <= n {
                h ^= UInt64(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: UInt32.self))) &* XXH64.p1
                h = XXH64.rotl(h, 23) &* XXH64.p2 &+ XXH64.p3
                i += 4
            }
            while i < n {
                h ^= UInt64(raw[i]) &* XXH64.p5
                h = XXH64.rotl(h, 11) &* XXH64.p1
                i += 1
            }
        }
        h ^= h >> 33
        h = h &* XXH64.p2
        h ^= h >> 29
        h = h &* XXH64.p3
        h ^= h >> 32
        return h
    }

    static func hex(_ v: UInt64) -> String {
        let s = String(v, radix: 16)
        return String(repeating: "0", count: max(0, 16 - s.count)) + s
    }
}

// MARK: - Low-level file IO

enum IO {
    static let chunk = 8 << 20

    /// Hash a file with XXH64, bypassing the OS cache so the bytes really come from the disk.
    static func hashFile(_ path: String, cancel: CancelFlag?, progress: (Int) -> Void = { _ in }) throws -> String {
        let fd = Darwin.open(path, O_RDONLY)
        if fd < 0 { throw AppError.io("Couldn't open \((path as NSString).lastPathComponent): \(errnoText())") }
        defer { Darwin.close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16384)
        defer { buf.deallocate() }
        var h = XXH64()
        while true {
            if cancel?.isCancelled == true { throw AppError.cancelled }
            let n = Darwin.read(fd, buf, chunk)
            if n < 0 {
                if errno == EINTR { continue }
                throw AppError.io("Couldn't read \((path as NSString).lastPathComponent): \(errnoText())")
            }
            if n == 0 { break }
            h.update(UnsafeRawBufferPointer(start: buf, count: n))
            progress(n)
        }
        return XXH64.hex(h.digest())
    }

    static func writeAll(_ fd: Int32, _ p: UnsafeRawPointer, _ n: Int) -> String? {
        var off = 0
        while off < n {
            let w = Darwin.write(fd, p.advanced(by: off), n - off)
            if w < 0 {
                if errno == EINTR { continue }
                return errnoText()
            }
            off += w
        }
        return nil
    }
}
