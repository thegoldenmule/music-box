import Foundation
import PolicyEngine
import SwiftData

/// Which setting a decision is about.
public enum SandboxSettingKey: String, Sendable, CaseIterable {
    case mode
    case unratedBehavior
}

/// Decision rows, not Kid attributes — a merge can't silently revert them.
@Model
public final class SandboxSettingRecord {
    public private(set) var id: UUID = UUID()

    /// A relationship: `buildPolicy()` runs on every 10Hz `queuedVerdict` poll.
    public var kid: Kid?

    /// ``SandboxSettingKey/rawValue``.
    public private(set) var keyRaw: String = SandboxSettingKey.mode.rawValue

    /// A string, so a future build's value reads back as unrecognised, not trapped.
    public private(set) var rawValue: String = ""

    /// When the decision was made, by the deciding device's clock.
    public private(set) var decidedAt: Date = Date.distantPast

    /// Opaque record name, for the admin's history line only, never for permission.
    public private(set) var decidedByAccountRecordName: String?

    public private(set) var decidedByGrownUpID: UUID?
    public private(set) var originatingDeviceID: UUID?
    public private(set) var modifiedAt: Date = Date.distantPast

    public init(
        id: UUID = UUID(),
        key: SandboxSettingKey,
        rawValue: String,
        decidedByAccountRecordName: String? = nil,
        decidedByGrownUpID: UUID? = nil,
        originatingDeviceID: UUID? = nil,
        at: Date = .now
    ) {
        self.id = id
        self.keyRaw = key.rawValue
        self.rawValue = rawValue
        self.decidedByAccountRecordName = decidedByAccountRecordName
        self.decidedByGrownUpID = decidedByGrownUpID
        self.originatingDeviceID = originatingDeviceID
        self.decidedAt = at
        self.modifiedAt = at
    }

    public var key: SandboxSettingKey? { SandboxSettingKey(rawValue: keyRaw) }
}

// MARK: - Which decision is in force

/// Wrong-narrow is a one-tap fix; wrong-wide hands out reach nobody agreed to.
public enum SandboxSettingResolution {
    /// Narrow to wide; `allowOnly` is tightest, `reportOnly` has no wall.
    static let modeOrder: [SandboxMode] = [.allowOnly, .denyPlusAuto, .reportOnly]

    /// Narrow to wide; `block` treats an unrated item as explicit.
    static let unratedOrder: [UnratedBehavior] = [.block, .inheritFromAncestor, .allow]

    static func narrower(_ a: SandboxMode, _ b: SandboxMode) -> SandboxMode {
        let ia = modeOrder.firstIndex(of: a) ?? 0
        let ib = modeOrder.firstIndex(of: b) ?? 0
        return ia <= ib ? a : b
    }

    static func narrower(_ a: UnratedBehavior, _ b: UnratedBehavior) -> UnratedBehavior {
        let ia = unratedOrder.firstIndex(of: a) ?? 0
        let ib = unratedOrder.firstIndex(of: b) ?? 0
        return ia <= ib ? a : b
    }

    /// A future-dated unreadable row is skipped, never guessed at as a vote.
    static func resolve<Value>(
        _ records: [SandboxSettingRecord],
        key: SandboxSettingKey,
        parse: (String) -> Value?,
        narrower: (Value, Value) -> Value
    ) -> Value? {
        let candidates =
            records
            .filter { $0.keyRaw == key.rawValue }
            .compactMap { record -> (Date, Value)? in
                guard let value = parse(record.rawValue) else { return nil }
                return (record.decidedAt, value)
            }

        guard let newest = candidates.map(\.0).max() else { return nil }

        return
            candidates
            .filter { newest.timeIntervalSince($0.0) < PolicyEntryRecord.clockSkewWindow }
            .map(\.1)
            .reduce(nil) { (winner: Value?, value: Value) in
                guard let winner else { return value }
                return narrower(winner, value)
            }
    }
}
