import Foundation
import PolicyEngine

/// A policy read out of storage, plus whatever could not be read.
public struct PolicyBuild: Sendable {
    public let policy: Policy

    /// Empty in every normal case — a row lands here only through corruption.
    public let unreadableEntryIDs: [UUID]

    /// Separate from entry IDs: a suggestion id looks up to nothing in `kid.entries`.
    public let unreadableSuggestionIDs: [UUID]

    public var hasUnreadableEntries: Bool { !unreadableEntryIDs.isEmpty }

    public var hasUnreadableSuggestions: Bool { !unreadableSuggestionIDs.isEmpty }

    public init(
        policy: Policy,
        unreadableEntryIDs: [UUID] = [],
        unreadableSuggestionIDs: [UUID] = []
    ) {
        self.policy = policy
        self.unreadableEntryIDs = unreadableEntryIDs
        self.unreadableSuggestionIDs = unreadableSuggestionIDs
    }
}

extension Kid {
    /// Unreadable rows fail closed: a bad `kind` becomes a deny, never a drop.
    public func buildPolicy() -> PolicyBuild {
        var built: [PolicyEntry] = []
        var unreadable: [UUID] = []
        var unreadableSuggestions: [UUID] = []

        // isLive's skew rule resolves a race toward hiding the item, never unblocking it.
        for record in entries where record.isLive {
            if let entry = record.entry {
                built.append(entry)
                continue
            }

            unreadable.append(record.id)

            if let itemKind = ItemKind(rawValue: record.itemKind) {
                built.append(.deny(CatalogID(itemKind, record.catalogID)))
            }
        }

        // Corrupt suggestions are dropped, not denied — a deny wins in every mode.
        for record in suggestions where !record.isDismissed {
            guard record.target != nil else {
                unreadableSuggestions.append(record.id)
                continue
            }
            built.append(contentsOf: record.allowedIDs.map(PolicyEntry.allow))
        }

        return PolicyBuild(
            policy: Policy(
                // Falls back to the cached columns, never a constant; see `Kid/effectiveMode`.
                mode: effectiveMode,
                entries: built,
                unratedBehavior: effectiveUnratedBehavior
            ),
            unreadableEntryIDs: unreadable,
            unreadableSuggestionIDs: unreadableSuggestions
        )
    }

    /// Discards the unreadable-row report; use `buildPolicy()` where it can be shown.
    public func makeEngine() -> PolicyEngine {
        PolicyEngine(policy: buildPolicy().policy)
    }
}
