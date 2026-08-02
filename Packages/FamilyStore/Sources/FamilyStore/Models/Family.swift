import Foundation
import SwiftData

/// One household. Holds kids and the grown-ups who curate for them.
///
/// It exists as a record with its own identifier rather than being implied by
/// "whatever is in this store" because it is the unit that gets shared. When a
/// second parent joins, the thing they are joining has to already have an
/// identity that predates them.
@Model
public final class Family {
    /// Generated at creation, never derived from position or content.
    ///
    /// Not `@Attribute(.unique)`: CloudKit rejects unique constraints, and this
    /// schema is written to be syncable without a migration.
    public private(set) var id: UUID = UUID()
    public private(set) var modifiedAt: Date = Date.distantPast

    @Relationship(deleteRule: .cascade, inverse: \Kid.family)
    public private(set) var kids: [Kid] = []

    /// The adults, in the order they were added. Allowed to be empty.
    ///
    /// On the family rather than on each kid: "Dad" is Dad to everyone in the
    /// house, and a per-kid roster would be the same adult typed once per child
    /// with nothing keeping the spellings together.
    ///
    /// Which of these is at the keyboard is **not** here. That describes a
    /// device, not the household, so it never enters this store — see
    /// `ActingGrownUpStore` in `AdminGate`.
    @Relationship(deleteRule: .cascade, inverse: \GrownUp.family)
    public private(set) var grownUps: [GrownUp] = []

    public init(id: UUID = UUID(), at: Date = .now) {
        self.id = id
        self.modifiedAt = at
        self.kids = []
        self.grownUps = []
    }

    /// Adds a child, and puts them at the end of the order.
    ///
    /// The index is assigned here rather than left for the next launch's capture
    /// so that a roster does not depend on when the app was last restarted. A
    /// child arriving from another device already carries one and keeps it.
    @discardableResult
    public func addKid(_ kid: Kid, at: Date = .now) -> Kid {
        let next = (kids.compactMap(\.sortIndex).max() ?? -1) + 1
        kids.append(kid)
        kid.family = self
        if kid.sortIndex == nil { kid.setSortIndex(next, at: at) }
        modifiedAt = at
        return kid
    }

    public func removeKid(_ kid: Kid, at: Date = .now) {
        kids.removeAll { $0.id == kid.id }
        modifiedAt = at
    }

    // MARK: - Grown-ups

    /// Adds an adult, and puts them at the end of the roster. See ``addKid(_:at:)``.
    @discardableResult
    public func addGrownUp(_ grownUp: GrownUp, at: Date = .now) -> GrownUp {
        let next = (grownUps.compactMap(\.sortIndex).max() ?? -1) + 1
        grownUps.append(grownUp)
        grownUp.family = self
        if grownUp.sortIndex == nil { grownUp.setSortIndex(next, at: at) }
        modifiedAt = at
        return grownUp
    }

    /// Takes a grown-up off the roster. **Leaves their rows alone.**
    ///
    /// Every suggestion and list entry they made keeps its `addedBy` and its
    /// copied `addedByName`, so their shelf keeps its heading and a child does not
    /// watch "From Dad" become "From your grown-up" because an adult tidied a
    /// settings screen. That is the write-time copy earning its keep, and it is
    /// deliberate rather than an oversight in the cascade.
    ///
    /// Detaches only — the caller deletes through the context, the way
    /// ``removeKid(_:at:)``'s does. `removeAll()` on a relationship nulls the
    /// inverse and leaves the row on disk.
    public func removeGrownUp(_ grownUp: GrownUp, at: Date = .now) {
        grownUps.removeAll { $0.id == grownUp.id }
        modifiedAt = at
    }

    public func grownUp(_ id: UUID) -> GrownUp? {
        grownUps.first { $0.id == id }
    }

    // MARK: - Order
    //
    // `kids` and `grownUps` are to-many relationships, and CloudKit does not
    // preserve to-many ordering — this file already says so about the adults
    // being "in the order they were added", which was true of one device and
    // will not be of two. Both rosters carry a `sortIndex` now, captured once by
    // `FamilyResolution.captureRosterOrder(of:at:)`, and these are the accessors
    // that use it. **Nothing should read the relationships directly for
    // display.**

    /// The children, in the order a parent put them in.
    ///
    /// A row with no captured index sorts last rather than first, so a child
    /// added on a build that has not run the capture cannot silently jump to the
    /// top of the admin's list. Ties break on the identifier, which is arbitrary
    /// and identical on every device.
    public var orderedKids: [Kid] {
        kids.sorted { ($0.sortIndex ?? .max, $0.id.uuidString) < ($1.sortIndex ?? .max, $1.id.uuidString) }
    }

    /// The adults, in the order their shelves appear on the kid's home screen.
    public var orderedGrownUps: [GrownUp] {
        grownUps.sorted { ($0.sortIndex ?? .max, $0.id.uuidString) < ($1.sortIndex ?? .max, $1.id.uuidString) }
    }

    /// Renames a grown-up **and corrects every copy of the old name.**
    ///
    /// The copies are the point. `addedByName` is snapshotted at write time so a
    /// shelf renders offline, which is the right trade for an album title and the
    /// wrong one for this: a child reads this name off their home screen daily,
    /// and a parent who fixes a typo expects the typo to go. So a rename walks
    /// every kid's suggestions and list entries and rewrites the ones pointing at
    /// this grown-up.
    ///
    /// It costs a `modifiedAt` stamp per touched row, which is exactly the sync
    /// churn this store avoids elsewhere. Spent knowingly and only here: a rename
    /// is rare, and a stale name on the kid's screen is not a thing worth saving
    /// writes over.
    public func renameGrownUp(_ grownUp: GrownUp, to newName: String, at: Date = .now) {
        grownUp.rename(to: newName, at: at)
        let attribution = grownUp.attribution
        for kid in kids {
            kid.rewriteAttribution(of: attribution, to: newName, at: at)
        }
        modifiedAt = at
    }
}
