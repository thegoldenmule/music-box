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

    /// The opaque `CKContainer.userRecordID.recordName` for the Apple Account
    /// that accepted the family share as this grown-up. `nil` until one does,
    /// which is every row today.
    ///
    /// **It can only be captured at acceptance**, which is why the column goes
    /// in before there is a share rather than when one is needed: adding it
    /// afterwards means re-inviting every adult who already joined.
    ///
    /// **A hint, never an authorization and never a key.** It does not open the
    /// gate, does not widen what any kid may reach, and nothing points at it. It
    /// is *allowed to be wrong* — dev and production CloudKit are separate
    /// databases and survival across a reinstall is reported rather than
    /// documented — so every path that reads it needs a working answer when it
    /// is stale. What it buys is one upgrade and no more: ``ActingGrownUp`` is a
    /// claim, and where this matches the account signed in on the device, it
    /// becomes something checkable.
    ///
    /// Only the record name. Never `CKUserIdentity.nameComponents`, never
    /// `lookupInfo` — App Review guideline 5.1.4 names persistent identifiers
    /// *used in combination with* a minor's data as the trigger, and an email
    /// address beside a child's search history is the combination.
    public private(set) var accountRecordName: String?

    /// Where this adult sits on the roster, which is the order their shelves
    /// appear in on the kid's home screen.
    ///
    /// `nil` until captured. See
    /// ``FamilyResolution/captureRosterOrder(of:at:)`` — this one is read by a
    /// child off their own home screen daily, so "Dad above Mum" is not
    /// cosmetic to them.
    public private(set) var sortIndex: Int?

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

    /// See ``FamilyResolution/captureRosterOrder(of:at:)``.
    public func setSortIndex(_ index: Int, at: Date = .now) {
        sortIndex = index
        modifiedAt = at
    }

    /// Records which Apple Account joined as this grown-up.
    ///
    /// Set once at share acceptance and cleared only when they leave. Passing
    /// `nil` un-claims the row, which is what removing a participant means here
    /// — the roster entry survives, because their name is on everything they
    /// curated and a child should not watch "From Dad" become "From your
    /// grown-up" because an adult changed phones.
    public func claim(account recordName: String?, at: Date = .now) {
        accountRecordName = recordName
        modifiedAt = at
    }

    /// What a row stores to point back here.
    ///
    /// The identifier and not the name: two grown-ups may share a name, and the
    /// shelf must still split.
    public var attribution: String { id.uuidString }
}
