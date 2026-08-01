import Foundation
import SwiftData

/// One adult in the household, by the name their kid calls them.
///
/// **A name, not an account.** There is still one admin passcode and one gate;
/// this record says who is *acting* behind it, not who is authorised. The app
/// knows who claims to be curating, not who is — which is the same standing view
/// gating has once the zone is shared, and it is a product control rather than a
/// security boundary.
///
/// It exists as a record with its own identifier rather than as a string on
/// ``Family`` because two adults suggest separately: the name belongs to the
/// suggestion, not to the household. Rows point back here by
/// ``id`` and carry a copy of ``name`` taken at write time, so a grown-up removed
/// from the roster still reads as a name on the shelf they built.
///
/// A roster is allowed to be empty, and starts that way. Every row then stamps
/// `nil`, every shelf falls back to "From your grown-up", and the app behaves
/// exactly as it did before this record existed.
@Model
public final class GrownUp {
    /// Generated at creation, never derived from position or content.
    ///
    /// Not `@Attribute(.unique)`: CloudKit rejects unique constraints, and this
    /// schema is written to be syncable without a migration.
    public private(set) var id: UUID = UUID()

    /// What the kid calls them — "Dad", "Mum", "Nana". Read by a child off their
    /// own home screen, which is the only reason this is free text an adult types
    /// rather than a picked relationship.
    public private(set) var name: String = ""

    public private(set) var modifiedAt: Date = Date.distantPast

    public var family: Family?

    public init(id: UUID = UUID(), name: String, at: Date = .now) {
        self.id = id
        self.name = name
        self.modifiedAt = at
    }

    /// Renames the grown-up. **Does not touch the copies.**
    ///
    /// Rows carry `addedByName` copied at write time, and correcting those is
    /// ``Family/renameGrownUp(_:to:at:)`` — which needs the kids to walk and so
    /// cannot live here. Calling this one directly leaves a shelf reading the old
    /// name, which is right for a rename that is not meant to be seen by the kid
    /// and wrong for every other one.
    public func rename(to newName: String, at: Date = .now) {
        name = newName
        modifiedAt = at
    }

    /// What a row stores to point back here.
    ///
    /// The identifier and not the name: two grown-ups may share a name, and the
    /// shelf must still split.
    public var attribution: String { id.uuidString }
}
