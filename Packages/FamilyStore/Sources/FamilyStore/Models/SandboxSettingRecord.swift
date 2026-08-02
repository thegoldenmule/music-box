import Foundation
import PolicyEngine
import SwiftData

/// Which setting a decision is about.
public enum SandboxSettingKey: String, Sendable, CaseIterable {
    case mode
    case unratedBehavior
}

/// One decision about how wide a child's sandbox is.
///
/// **Why these two fields left `Kid`.** `mode` and `unratedBehavior` decide what
/// a child can reach, and they sat as attributes on the same record as `name`.
/// Under any whole-record merge — which is what a mirroring layer gives you, and
/// what a careless mapper gives you too — a parent tightening the mode on one
/// device while another renames the child on a second resolves as one record
/// winning. Roughly half the time that is the rename, and **the tightening
/// vanishes with nothing on any screen to say so.** A parent who set Level 1
/// would find Level 2 in force and no reason to look.
///
/// As decision rows, a rename can never contend with a mode change, a heart tap
/// can never revert a sandbox level, and the admin has something honest to show:
/// *"You set Level 1 at 16:02. Dad set Level 2 at 16:05."*
///
/// **Append-only.** A decision is a fact about a moment and is never edited; a
/// parent changing their mind writes another row. That is also what makes the
/// history above possible.
///
/// **`Kid.mode` and `Kid.unratedBehavior` stay** as a denormalised cache, and
/// this is deliberate rather than transitional. Keeping them means this change
/// is purely additive — no frozen schema version, no custom migration stage, no
/// rewriting of a family's live curation — and a store that predates this table
/// is simply a store where the columns are the only answer, which is the correct
/// answer for it. See ``Kid/effectiveMode`` for the resolution order. They are a
/// cache and never the authority: nothing may read them directly.
@Model
public final class SandboxSettingRecord {
    public private(set) var id: UUID = UUID()

    /// Whose sandbox.
    ///
    /// A relationship, unlike ``DeviceRecord`` and the other new records, and
    /// for one reason: this is read on the policy hot path. `buildPolicy()` runs
    /// on every `queuedVerdict`, which the player polls at 10Hz through the last
    /// seconds of a track, and a context fetch there is exactly what the cached
    /// engine exists to avoid. The mapper encodes `kid?.id`, the same way it
    /// does for `Kid.family`.
    public var kid: Kid?

    /// ``SandboxSettingKey/rawValue``.
    public private(set) var keyRaw: String = SandboxSettingKey.mode.rawValue

    /// The decided value, as the enum's raw string.
    ///
    /// A string and not a typed enum, so that a value a future build writes
    /// reads back as *unrecognised* on an older one rather than trapping inside
    /// a SwiftData accessor. `mode` and `unratedBehavior` on `Kid` are the only
    /// two enums in this store that were ever stored typed, and they were the
    /// two most safety-critical; this is where that is corrected.
    public private(set) var rawValue: String = ""

    /// When the decision was made, by the deciding device's clock.
    public private(set) var decidedAt: Date = Date.distantPast

    /// Which Apple Account decided, opaque record name only. For the admin's
    /// history line, never for permission.
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

/// How two decisions that were made at nearly the same moment resolve.
///
/// The window is ``PolicyEntryRecord/clockSkewWindow``, and the rule is the same
/// one: inside it, two device clocks do not agree what "after" means, so taking
/// the later timestamp is taking whichever device ran fast. **The narrower
/// setting wins.**
///
/// Which direction that has to fail in is not a close call. Choosing wrong
/// toward *narrow* shows a parent a stricter sandbox than they picked, on the
/// screen they are already looking at, fixable in one tap. Choosing wrong toward
/// *wide* hands a child reach that two adults between them never agreed to, and
/// nothing anywhere says so.
public enum SandboxSettingResolution {
    /// Narrow to wide. `allowOnly` is the tightest wall there is; `reportOnly`
    /// has none.
    static let modeOrder: [SandboxMode] = [.allowOnly, .denyPlusAuto, .reportOnly]

    /// Narrow to wide. `block` treats an unrated item as explicit.
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

    /// Resolves a set of decisions for one key down to one value.
    ///
    /// Latest `decidedAt` wins, except that every decision within
    /// ``PolicyEntryRecord/clockSkewWindow`` of the latest is folded in
    /// narrowest-first. A row whose stored value this build cannot read is
    /// **skipped**, not treated as a vote: it is a value from the future, and
    /// guessing what it meant is how a newer build's tightening becomes an older
    /// build's default.
    ///
    /// `nil` when there are no readable decisions at all, which is what sends
    /// the caller to the cached column.
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
