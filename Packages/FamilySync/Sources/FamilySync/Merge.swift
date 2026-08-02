import Foundation

/// How one field reconciles when two devices have both changed it.
public enum FieldRule: Sendable, Equatable {
    /// Both sides only ever move it forward, so the later value is the later
    /// fact. Order-independent and needs no ancestor.
    ///
    /// This is what makes retraction work: `assertedAt` and `retractedAt` both
    /// take their maximum, and `PolicyEntryRecord.isLive` then decides. Two
    /// parents editing one list offline never co-write a value, so there is
    /// nothing to arbitrate — which is the whole reason the store stopped
    /// deleting rows.
    case latest

    /// Both sides only ever move it backward, or it should never move at all.
    /// `addedAt`, `createdAt`, `favoritedAt` — the moment something began.
    ///
    /// Earliest rather than latest because a re-add on one device must not
    /// rewrite the sentence the admin shows a parent: *"you added this on
    /// Tuesday."*
    case earliest

    /// Cosmetic. Whichever record was touched most recently wins the field, on
    /// the record's own `modifiedAt`. A display name, an artwork URL, a note.
    ///
    /// The name is doing work: **anything routed here is something the app is
    /// willing to lose one edit of.** Nothing that decides what a child can
    /// reach may use it.
    case newerRecord

    /// A value that is absent until it is set, and once set is a fact. Prefers
    /// whichever side has one; if both, the earlier.
    case sticky

    /// Never changes after creation. Both sides must agree; if they do not, the
    /// local value is kept and the disagreement is reported rather than
    /// silently resolved.
    case immutable
}

/// Reconciles two versions of one record.
///
/// **Plain values in, one value out. No CloudKit, no network, no device, no
/// clock.** That is what lets the rules below be exhausted by `swift test`,
/// which matters more here than anywhere else in the project: this is the code
/// that decides whether a parent's deny survives a merge, and the verification
/// budget off-device is `swift test` and two builds.
///
/// **There is no whole-record last-write-wins anywhere in here**, which is the
/// thing the spec forbids outright. Every field is reconciled on its own terms,
/// so a rename can never swallow a tightening and a heart tap can never revert
/// a sandbox level.
///
/// The ancestor is optional because CloudKit only sometimes provides one
/// (`CKRecordChangedErrorAncestorRecordKey`). Every rule above is written to be
/// correct without it — the ancestor improves reporting, never the outcome.
public enum Merge {
    /// What a merge decided, alongside anything a person should know about.
    public struct Outcome: Sendable, Equatable {
        public let record: SyncedRecord

        /// Fields where the two sides disagreed on something declared
        /// ``FieldRule/immutable``.
        ///
        /// Surfaced rather than swallowed. An immutable field disagreeing means
        /// two records that share a natural key are not the same thing, which is
        /// either a key that is too loose or a bug — and both are worth knowing
        /// about before they are a support question.
        public let conflicts: [String]

        public init(record: SyncedRecord, conflicts: [String] = []) {
            self.record = record
            self.conflicts = conflicts
        }
    }

    /// Merges `remote` into `local`.
    ///
    /// **Commutative by construction.** Every rule is a function of the two
    /// values and nothing else — no "whoever arrived second", no bias toward
    /// local — so a device that syncs A-then-B lands in the same state as one
    /// that syncs B-then-A. That property is what the offline exit test is
    /// actually checking, and it is why the rules are max/min/compare rather
    /// than anything that reads like a merge algorithm.
    public static func resolve(
        local: SyncedRecord,
        remote: SyncedRecord,
        rules: [String: FieldRule],
        default defaultRule: FieldRule = .newerRecord
    ) -> Outcome {
        precondition(local.type == remote.type, "merging records of different types")

        let localTouched = local.date(Field.modifiedAt) ?? .distantPast
        let remoteTouched = remote.date(Field.modifiedAt) ?? .distantPast
        let remoteIsNewer = remoteTouched > localTouched

        var fields = local.fields
        var conflicts: [String] = []

        for key in Set(local.fields.keys).union(remote.fields.keys) {
            let mine = local.fields[key]
            let theirs = remote.fields[key]

            // One side simply does not carry the field — an older build, or a
            // value never set. Absence is not a vote to remove something.
            guard let mine else {
                fields[key] = theirs
                continue
            }
            guard let theirs else { continue }
            guard mine != theirs else { continue }

            switch rules[key] ?? defaultRule {
            case .latest:
                fields[key] = laterOf(mine, theirs)
            case .earliest:
                fields[key] = earlierOf(mine, theirs)
            case .newerRecord:
                fields[key] = remoteIsNewer ? theirs : mine
            case .sticky:
                fields[key] = earlierOf(mine, theirs)
            case .immutable:
                conflicts.append(key)
            }
        }

        // `modifiedAt` describes the merged record, and the merged record is at
        // least as new as either side.
        fields[Field.modifiedAt] = .date(max(localTouched, remoteTouched))
        fields = biasedTowardNarrower(fields, type: local.type)

        return Outcome(
            record: SyncedRecord(name: local.name, type: local.type, fields: fields),
            conflicts: conflicts.sorted()
        )
    }

    /// How far apart two device clocks are assumed to be able to drift.
    public static let clockSkewWindow: TimeInterval = 120

    /// Breaks a tie the timestamps cannot, in the direction that costs least
    /// when it is wrong.
    ///
    /// **This is the only place in the system that guesses**, and it is here
    /// rather than on the record because this is the only place two device
    /// clocks meet. When a withdrawal and an assertion land within
    /// ``clockSkewWindow`` of each other, neither device is wrong — they simply
    /// do not agree what *after* means, and taking the later timestamp is taking
    /// whichever device ran fast.
    ///
    /// So the answer is chosen by consequence instead:
    ///
    /// - A **deny stands.** A phantom deny hides one item a parent meant to
    ///   allow — on the screen they are already looking at, fixable in one tap.
    ///   A deny that loses a coin toss silently un-blocks something a parent
    ///   explicitly refused, and nothing anywhere says so.
    /// - An **allow does not.** Same asymmetry, same direction.
    /// - A **dismissal stands**, because it withdraws an allow.
    ///
    /// The adjustment is a nudge to the losing timestamp rather than a flag, so
    /// the result stays a plain pair of dates that any build can compare — and
    /// so it stays commutative, which a flag written by whichever side merged
    /// first would not be.
    private static func biasedTowardNarrower(
        _ fields: [String: SyncValue], type: String
    ) -> [String: SyncValue] {
        var fields = fields

        func nudge(_ winner: String, over loser: String) {
            guard case .date(let w)? = fields[winner], case .date(let l)? = fields[loser] else {
                return
            }
            guard w <= l, l.timeIntervalSince(w) < clockSkewWindow else { return }
            fields[winner] = .date(l.addingTimeInterval(1))
        }

        switch type {
        case "PolicyEntryRecord":
            guard case .string(let kind)? = fields["kind"] else { return fields }
            // Only where there is something to compare against. A row nobody has
            // withdrawn cannot be in a tie, and normalising it anyway would
            // rewrite `assertedAt` on every merge of an untouched record —
            // churn on a record that has not changed.
            guard fields[Field.retractedAt] != nil else { return fields }

            // The effective assertion reads through to `addedAt`, exactly as
            // `PolicyEntryRecord.assertion` does — a row that has only ever been
            // added once carries `.distantPast` in `assertedAt`, and comparing
            // *that* against a retraction would put every such row far outside
            // the window and skip the rule entirely.
            if case .date(let added)? = fields[Field.addedAt] {
                let asserted: Date
                if case .date(let value)? = fields[Field.assertedAt] { asserted = value } else {
                    asserted = .distantPast
                }
                fields[Field.assertedAt] = .date(max(asserted, added))
            }

            if kind == "deny" {
                // Assertion wins: the deny stands.
                nudge(Field.assertedAt, over: Field.retractedAt)
            } else {
                // Retraction wins: the allow does not.
                nudge(Field.retractedAt, over: Field.assertedAt)
            }
        case "SuggestionRecord":
            nudge(Field.dismissedAt, over: Field.restoredAt)
        default:
            break
        }

        return fields
    }

    private static func laterOf(_ a: SyncValue, _ b: SyncValue) -> SyncValue {
        guard case .date(let x) = a, case .date(let y) = b else { return a }
        return .date(max(x, y))
    }

    private static func earlierOf(_ a: SyncValue, _ b: SyncValue) -> SyncValue {
        guard case .date(let x) = a, case .date(let y) = b else { return a }
        return .date(min(x, y))
    }
}

/// Field names, in one place, because a typo in one of these is a field that
/// silently never merges.
public enum Field {
    public static let id = "id"
    public static let modifiedAt = "modifiedAt"
    public static let addedAt = "addedAt"
    public static let assertedAt = "assertedAt"
    public static let retractedAt = "retractedAt"
    public static let dismissedAt = "dismissedAt"
    public static let restoredAt = "restoredAt"
    public static let createdAt = "createdAt"
    public static let favoritedAt = "favoritedAt"
    public static let suggestedAt = "suggestedAt"
    public static let decidedAt = "decidedAt"
    public static let revokedAt = "revokedAt"
    public static let lastSeenAt = "lastSeenAt"
    public static let enrolledAt = "enrolledAt"
    public static let position = "position"
    public static let sortIndex = "sortIndex"
    public static let name = "name"
    public static let displayName = "displayName"
    public static let kidID = "kidID"
    public static let familyID = "familyID"
}

// MARK: - The rules, per record type

extension Merge {
    /// The rule table. **This is the design**, not configuration for it.
    ///
    /// Anything absent falls to ``FieldRule/newerRecord``, which is the only
    /// rule that can lose an edit — so the test that matters here is not that
    /// these entries are right but that nothing safety-critical is *missing*
    /// from them.
    public static func rules(for type: String) -> [String: FieldRule] {
        var table: [String: FieldRule] = [
            Field.id: .immutable,
            Field.createdAt: .earliest,
        ]

        switch type {
        case "PolicyEntryRecord":
            // The entry-level merge, and the whole reason removal became a
            // retraction. Both timestamps only move forward, so taking each
            // one's maximum is order-independent and `isLive` decides the rest —
            // including the skew rule that keeps a deny standing when the two
            // are too close to call.
            table[Field.addedAt] = .earliest
            table[Field.assertedAt] = .latest
            table[Field.retractedAt] = .latest

        case "SuggestionRecord":
            // Same shape, because a dismissal withdraws an allow. `restore` used
            // to clear `dismissedAt`, which threw away the fact this comparison
            // needs — a device that had not seen the restore would have won with
            // a bare dismissal and a parent's re-offer would vanish.
            table[Field.dismissedAt] = .latest
            table[Field.restoredAt] = .latest
            table[Field.suggestedAt] = .earliest

        case "SandboxSettingRecord":
            // Append-only decisions: one record *is* one decision, so two copies
            // of it are identical and there is nothing to reconcile. Which
            // decision is in force is resolved across rows in `FamilyStore`,
            // narrowest-wins inside the skew window — deliberately not here,
            // because it is a question about a set rather than about a record.
            table[Field.decidedAt] = .immutable

        case "FavoriteRecord":
            // A shelf ordered most-recent-first must not reshuffle because
            // something was adopted again on a later read.
            table[Field.favoritedAt] = .earliest

        case "DeviceRecord":
            // Revocation is a tombstone and must not be undone by a device that
            // has not heard about it yet. `lastSeenAt` is the one genuinely
            // racing field and the later answer is the true one.
            table[Field.revokedAt] = .sticky
            table[Field.enrolledAt] = .earliest
            table[Field.lastSeenAt] = .latest

        case "HistoryClearRecord", "ConsentRecord", "PasscodeEpochRecord":
            // Statements about a moment. They are written once and never edited,
            // so any disagreement is a key collision rather than a merge.
            table[Field.id] = .immutable

        case "ActivitySegmentRecord":
            // Keyed by the writing device, so two devices never write the same
            // segment and this table is here for completeness rather than use.
            break

        default:
            break
        }

        return table
    }
}
