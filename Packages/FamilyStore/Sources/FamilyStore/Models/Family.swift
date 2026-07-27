import Foundation
import SwiftData

/// One household. Holds kids; owns nothing else.
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

    public init(id: UUID = UUID(), at: Date = .now) {
        self.id = id
        self.modifiedAt = at
        self.kids = []
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
}
