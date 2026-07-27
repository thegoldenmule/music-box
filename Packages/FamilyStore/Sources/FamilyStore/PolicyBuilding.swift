import Foundation
import PolicyEngine

/// A policy read out of storage, plus whatever could not be read.
///
/// Two values rather than one because the failure is not silent: an unreadable
/// row is something the admin should be able to show a parent, not something
/// the engine quietly works around.
public struct PolicyBuild: Sendable {
    public let policy: Policy

    /// Entry rows whose stored strings did not read back cleanly. Empty in
    /// every normal case — these strings are written by our own code from typed
    /// enums, so a row lands here only through corruption or a schema we did
    /// not anticipate.
    public let unreadableEntryIDs: [UUID]

    public var hasUnreadableEntries: Bool { !unreadableEntryIDs.isEmpty }
}

extension Kid {
    /// Builds this kid's policy from stored values.
    ///
    /// The one read on the hot path. Both `mode` and `unratedBehavior` are used
    /// exactly as stored; no default is substituted here or anywhere below.
    ///
    /// **Unreadable rows fail closed.** A row whose `kind` is unreadable but
    /// whose identifier still parses is used as a *deny*, not dropped. The
    /// asymmetry is deliberate: a phantom deny hides one item a parent meant to
    /// allow, which is visible and fixable, while dropping a real deny silently
    /// unblocks something a parent explicitly refused. A row whose `itemKind`
    /// is unreadable cannot be turned into a `CatalogID` at all and is dropped
    /// — that one is reported and nothing else can be done with it.
    public func buildPolicy() -> PolicyBuild {
        var built: [PolicyEntry] = []
        var unreadable: [UUID] = []

        for record in entries {
            if let entry = record.entry {
                built.append(entry)
                continue
            }

            unreadable.append(record.id)

            if let itemKind = ItemKind(rawValue: record.itemKind) {
                built.append(.deny(CatalogID(itemKind, record.catalogID)))
            }
        }

        return PolicyBuild(
            policy: Policy(
                mode: mode,
                entries: built,
                unratedBehavior: unratedBehavior
            ),
            unreadableEntryIDs: unreadable
        )
    }

    /// An engine for this kid, built once and reused across a page of results.
    ///
    /// Discards the unreadable-row report. Use ``buildPolicy()`` where a
    /// surface can show it.
    public func makeEngine() -> PolicyEngine {
        PolicyEngine(policy: buildPolicy().policy)
    }
}
