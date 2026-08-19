import Foundation
import SwiftData

/// One household; has its own identity because it's the unit that gets shared.
@Model
public final class Family {
    /// Not `@Attribute(.unique)`: CloudKit rejects unique constraints.
    public private(set) var id: UUID = UUID()
    public private(set) var modifiedAt: Date = Date.distantPast

    @Relationship(deleteRule: .cascade, inverse: \Kid.family)
    public private(set) var kids: [Kid] = []

    /// On the family, not per-kid, so "Dad" isn't retyped once per child.
    @Relationship(deleteRule: .cascade, inverse: \GrownUp.family)
    public private(set) var grownUps: [GrownUp] = []

    public init(id: UUID = UUID(), at: Date = .now) {
        self.id = id
        self.modifiedAt = at
        self.kids = []
        self.grownUps = []
    }

    /// Index assigned here, not at capture, so order doesn't depend on restart timing.
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

    /// Leaves their rows alone: shelves keep "From Dad" instead of going nameless.
    public func removeGrownUp(_ grownUp: GrownUp, at: Date = .now) {
        grownUps.removeAll { $0.id == grownUp.id }
        modifiedAt = at
    }

    public func grownUp(_ id: UUID) -> GrownUp? {
        grownUps.first { $0.id == id }
    }

    /// One holder per account; a second claim un-claims the first — a hint.
    public func claimAccount(_ recordName: String?, for grownUp: GrownUp, at: Date = .now) {
        guard let recordName else {
            grownUp.claim(account: nil, at: at)
            modifiedAt = at
            return
        }

        // Runs every launch; a no-op write here would outbox the roster each time.
        guard grownUp.accountRecordName != recordName else { return }

        for other in grownUps where other.id != grownUp.id && other.accountRecordName == recordName
        {
            other.claim(account: nil, at: at)
        }
        grownUp.claim(account: recordName, at: at)
        modifiedAt = at
    }

    // MARK: - Order
    // CloudKit drops to-many order; `sortIndex` carries it, not the raw relation.

    /// An uncaptured index sorts last, not first, so a new child can't jump to top.
    public var orderedKids: [Kid] {
        kids.sorted { ($0.sortIndex ?? .max, $0.id.uuidString) < ($1.sortIndex ?? .max, $1.id.uuidString) }
    }

    /// The adults, in the order their shelves appear on the kid's home screen.
    public var orderedGrownUps: [GrownUp] {
        grownUps.sorted { ($0.sortIndex ?? .max, $0.id.uuidString) < ($1.sortIndex ?? .max, $1.id.uuidString) }
    }

    /// Also corrects every copied `addedByName` — rare enough to spend the sync churn.
    public func renameGrownUp(_ grownUp: GrownUp, to newName: String, at: Date = .now) {
        grownUp.rename(to: newName, at: at)
        let attribution = grownUp.attribution
        for kid in kids {
            kid.rewriteAttribution(of: attribution, to: newName, at: at)
        }
        modifiedAt = at
    }
}
