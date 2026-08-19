import Foundation
import SwiftData

/// A name, not an account — who's acting, not authorized; no security boundary.
@Model
public final class GrownUp {
    /// Not `@Attribute(.unique)` — CloudKit rejects unique constraints.
    public private(set) var id: UUID = UUID()

    /// What the kid calls them — free text, not a picked relationship.
    public private(set) var name: String = ""

    public private(set) var modifiedAt: Date = Date.distantPast

    /// Accepted-share Apple Account for this grown-up. `nil` until then.
    ///
    /// **Captured at acceptance only** — the column exists before it's needed, so
    /// adding it later wouldn't mean re-inviting everyone.
    ///
    /// **A hint, not an authorization.** It opens no gate and widens no reach; it
    /// may go stale (separate dev/prod CloudKit, reinstall survival unconfirmed),
    /// and every reader must tolerate that.
    ///
    /// Only the record name — never `nameComponents` or `lookupInfo`. 5.1.4 treats
    /// an identifier *beside* a minor's data as the trigger.
    public private(set) var accountRecordName: String?

    /// `nil` until captured — order is what a kid sees daily, not cosmetic.
    public private(set) var sortIndex: Int?

    public var family: Family?

    public init(id: UUID = UUID(), name: String, at: Date = .now) {
        self.id = id
        self.name = name
        self.modifiedAt = at
    }

    /// Doesn't touch copies — ``Family/renameGrownUp`` corrects those across kids.
    public func rename(to newName: String, at: Date = .now) {
        name = newName
        modifiedAt = at
    }

    /// See ``FamilyResolution/captureRosterOrder(of:at:)``.
    public func setSortIndex(_ index: Int, at: Date = .now) {
        sortIndex = index
        modifiedAt = at
    }

    /// `nil` un-claims but keeps the row — past "From Dad" shelves don't change.
    public func claim(account recordName: String?, at: Date = .now) {
        accountRecordName = recordName
        modifiedAt = at
    }

    /// The id, not the name — two grown-ups may share a name.
    public var attribution: String { id.uuidString }
}
