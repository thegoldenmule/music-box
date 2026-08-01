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

    @discardableResult
    public func addKid(_ kid: Kid, at: Date = .now) -> Kid {
        kids.append(kid)
        kid.family = self
        modifiedAt = at
        return kid
    }

    public func removeKid(_ kid: Kid, at: Date = .now) {
        kids.removeAll { $0.id == kid.id }
        modifiedAt = at
    }

    // MARK: - Grown-ups

    @discardableResult
    public func addGrownUp(_ grownUp: GrownUp, at: Date = .now) -> GrownUp {
        grownUps.append(grownUp)
        grownUp.family = self
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
