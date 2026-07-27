import Foundation
import PolicyEngine
import SwiftData

/// One kid, their walls, and their history.
///
/// Sandbox level is here rather than on ``Family`` because it is set per kid.
/// A seven-year-old and a twelve-year-old in the same house do not get the same
/// catalog.
@Model
public final class Kid {
    public private(set) var id: UUID = UUID()
    public private(set) var modifiedAt: Date = Date.distantPast
    public private(set) var name: String = ""

    /// Stored explicitly. **Never read from a global default at evaluation
    /// time** — if a constant were consulted instead, changing a recommended
    /// default in a later release would silently change what every existing kid
    /// can reach.
    ///
    /// The schema defaults below exist only because CloudKit requires every
    /// attribute to have one; the initializer always supplies both, so no real
    /// row ever falls back to them. They are the *most restrictive* values
    /// rather than the recommended ones, so that if one ever were consulted it
    /// would fail closed.
    public private(set) var mode: SandboxMode = SandboxMode.allowOnly
    public private(set) var unratedBehavior: UnratedBehavior = UnratedBehavior.block

    public var family: Family?

    @Relationship(deleteRule: .cascade, inverse: \PolicyEntryRecord.kid)
    public private(set) var entries: [PolicyEntryRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \SearchEventRecord.kid)
    public private(set) var searches: [SearchEventRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \PlayEventRecord.kid)
    public private(set) var plays: [PlayEventRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \BlockEventRecord.kid)
    public private(set) var blocks: [BlockEventRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \WeeklySummaryRecord.kid)
    public private(set) var summaries: [WeeklySummaryRecord] = []

    public init(
        id: UUID = UUID(),
        name: String,
        mode: SandboxMode,
        unratedBehavior: UnratedBehavior = .block,
        at: Date = .now
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.unratedBehavior = unratedBehavior
        self.modifiedAt = at
    }

    // MARK: - Mutation
    //
    // Every stored property is `private(set)` and changed only through these,
    // which stamp `modifiedAt`. The invariant is that every record carries the
    // time it last changed; leaving the properties writable would make that a
    // thing each caller had to remember, and sync merging later depends on it.

    public func rename(to newName: String, at: Date = .now) {
        name = newName
        modifiedAt = at
    }

    public func setMode(_ newMode: SandboxMode, at: Date = .now) {
        mode = newMode
        modifiedAt = at
    }

    public func setUnratedBehavior(_ behavior: UnratedBehavior, at: Date = .now) {
        unratedBehavior = behavior
        modifiedAt = at
    }

    // MARK: - Lists
    //
    // Callers must `save()` and surface a failure. A parent who taps deny and
    // gets silence must not be left believing the deny landed. This is the
    // opposite of event logging, which is fire-and-forget.

    @discardableResult
    public func addEntry(
        kind: PolicyEntry.Kind,
        id catalogID: CatalogID,
        displayName: String,
        artworkURL: URL? = nil,
        addedBy: String? = nil,
        at: Date = .now
    ) -> PolicyEntryRecord {
        let record = PolicyEntryRecord(
            kind: kind,
            catalogID: catalogID,
            displayName: displayName,
            artworkURL: artworkURL,
            addedBy: addedBy,
            at: at
        )
        attach(record, at: at)
        return record
    }

    func attach(_ record: PolicyEntryRecord, at: Date = .now) {
        entries.append(record)
        record.kid = self
        modifiedAt = at
    }

    public func removeEntry(_ record: PolicyEntryRecord, at: Date = .now) {
        entries.removeAll { $0.id == record.id }
        modifiedAt = at
    }

    // MARK: - Events
    //
    // Attaching an event deliberately does **not** stamp `modifiedAt`. That
    // field describes the kid record itself — their name, mode, unrated
    // behavior — and is what an entry-level merge will compare when two
    // parents' devices reconcile. Bumping it on every play would make a child
    // listening to music look like a parent editing settings, and would churn
    // the one record sync most needs to be quiet.

    func attach(_ record: SearchEventRecord) {
        searches.append(record)
        record.kid = self
    }

    func attach(_ record: PlayEventRecord) {
        plays.append(record)
        record.kid = self
    }

    func attach(_ record: BlockEventRecord) {
        blocks.append(record)
        record.kid = self
    }

    func attach(_ record: WeeklySummaryRecord) {
        summaries.append(record)
        record.kid = self
    }

    // MARK: - History

    /// Deletes this kid's history and nothing else.
    ///
    /// Summaries go too: one outliving the events it was derived from is a
    /// record the parent asked us to destroy. Lists, mode and unrated behavior
    /// stay — curation is not history, and a parent deleting a month of logs is
    /// not asking to rebuild their allow list.
    public func deleteHistory(at: Date = .now) {
        searches.removeAll()
        plays.removeAll()
        blocks.removeAll()
        summaries.removeAll()
        modifiedAt = at
    }
}
