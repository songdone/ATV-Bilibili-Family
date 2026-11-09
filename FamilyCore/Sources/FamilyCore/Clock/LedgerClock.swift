import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#endif

public struct LedgerClockSample: Codable, Equatable, Sendable {
    public let wallMilliseconds: Int64
    public let monotonicMilliseconds: Int64
    /// Identifies the process. Without a boot identity, continuity is only provable here.
    public let continuityID: String
    /// Versioned identity of the monotonic timebase; different sources must never be subtracted.
    /// Optional so payloads and clients predating clock provenance remain decodable.
    public let monotonicSource: String?
    /// OS boot marker: a boot UUID where available, otherwise a source-qualified
    /// kernel boot timeval. The fallback can drift during normal clock discipline;
    /// it is not a cryptographically unique boot identifier or a wall-minus-uptime
    /// guess. Only the ledger's bounded, fixed-anchor continuity checks may accept it.
    public let bootSessionID: String?

    public init(wallMilliseconds: Int64, monotonicMilliseconds: Int64, continuityID: String,
                monotonicSource: String? = nil, bootSessionID: String? = nil) {
        self.wallMilliseconds = wallMilliseconds
        self.monotonicMilliseconds = monotonicMilliseconds
        self.continuityID = continuityID
        self.monotonicSource = monotonicSource
        self.bootSessionID = bootSessionID
    }
}

public protocol LedgerClock: Sendable { func now() -> LedgerClockSample }

public struct SystemLedgerClock: LedgerClock {
    private static let processContinuityID = UUID().uuidString
    // Internal injection keeps the EPERM fallback and fresh-per-sample behavior
    // testable on macOS, where the production UUID read normally succeeds.
    private let readBootSessionID: @Sendable () -> String?

    public init() { readBootSessionID = { Self.systemBootSessionID() } }
    init(bootSessionIDProvider: @escaping @Sendable () -> String?) {
        readBootSessionID = bootSessionIDProvider
    }

    private static func systemBootSessionID() -> String? {
        #if canImport(Darwin)
        return bootSessionID(bootUUID: readBootUUID(), kernelBootTime: {
            var value = timeval()
            var size = MemoryLayout<timeval>.size
            // Public SDK KERN_BOOTTIME returns the kernel's stored timeval, not
            // a value calculated here from Date or any uptime source.
            guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0,
                  size == MemoryLayout<timeval>.size else { return nil }
            return (Int64(value.tv_sec), Int64(value.tv_usec))
        })
        #else
        return nil
        #endif
    }

    static func bootSessionID(bootUUID: String?,
                              kernelBootTime: () -> (seconds: Int64, microseconds: Int64)?) -> String? {
        // Preserve the UUID representation already written by this version.
        if let bootUUID, let uuid = UUID(uuidString: bootUUID) { return uuid.uuidString }
        guard let time = kernelBootTime(), time.seconds > 0,
              time.seconds <= 253_402_214_400,
              (0..<1_000_000).contains(time.microseconds) else { return nil }
        // Preserve exact sec/usec evidence. The ledger compares bounded drift;
        // rounding or bucketing here would hide cumulative changes at the boundary.
        return "kern-boottime-v1:\(time.seconds):\(time.microseconds)"
    }

    /// Only canonical, explicitly source-qualified kernel markers receive drift
    /// tolerance. UUIDs, unknown methods and malformed markers remain opaque IDs.
    static func kernelBootTimeMicroseconds(_ marker: String?) -> Int64? {
        guard let marker else { return nil }
        let parts = marker.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "kern-boottime-v1",
              let seconds = Int64(parts[1]), let microseconds = Int64(parts[2]),
              seconds > 0, seconds <= 253_402_214_400,
              (0..<1_000_000).contains(microseconds),
              marker == "kern-boottime-v1:\(seconds):\(microseconds)" else { return nil }
        return seconds * 1_000_000 + microseconds
    }

    #if canImport(Darwin)
    private static func readBootUUID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0,
              size > 1, size <= 128 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0,
              let end = bytes.firstIndex(of: 0), end > 0 else { return nil }
        return String(decoding: bytes[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    #endif

    public func now() -> LedgerClockSample {
        // Read fresh evidence on every sample. Normal discipline may move the
        // fallback; caching it would hide steps and defeat fixed-anchor checks.
        let bootSessionID = readBootSessionID()
        let monotonic = Self.monotonicSample()
        return LedgerClockSample(wallMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
                                 monotonicMilliseconds: monotonic.milliseconds,
                                 continuityID: Self.processContinuityID,
                                 monotonicSource: monotonic.source,
                                 bootSessionID: bootSessionID)
    }

    private static func monotonicSample() -> (milliseconds: Int64, source: String) {
        #if canImport(Darwin)
        // Unlike uptime, continuous time includes sleep. Never hide a fallback's source.
        var info = mach_timebase_info_data_t()
        if mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 {
            return (Int64(Double(mach_continuous_time()) * Double(info.numer)
                          / Double(info.denom) / 1_000_000), "mach-continuous-v1")
        }
        #endif
        return (Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000), "dispatch-uptime-v1")
    }
}
