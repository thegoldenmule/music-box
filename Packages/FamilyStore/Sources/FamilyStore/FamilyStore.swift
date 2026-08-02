import Foundation
import SwiftData

/// The store's schema and how to open it.
///
/// v1 is **local only**. Nothing here leaves the device: no server of ours, no
/// third-party analytics, no PII to anyone. That is a legal position, not an
/// architecture preference — this store holds a child's search history.
public enum FamilyStore {
    /// Every model, in one place, taken from the current schema version.
    ///
    /// The list lives in ``FamilySchemaV2`` rather than here so that the version
    /// identifier and the models it covers cannot drift apart. This stays the
    /// name the rest of the package opens the store by, so nothing above had to
    /// learn about versions.
    public static let schema = Schema(versionedSchema: FamilySchemaV2.self)

    /// Opens the store on disk, **migrating it if it was written by an older
    /// build**.
    ///
    /// **No migration plan, deliberately, and not as a deferral.** Everything
    /// added since the unversioned original is additive, and SwiftData migrates
    /// that by inference. Passing a plan whose earlier version is a list of
    /// *live* model types is worse than passing none: those types have since
    /// changed, so the version describes the wrong shape and a real store fails
    /// to open at all with `NSCocoaErrorDomain 134504, "Cannot use staged
    /// migration with an unknown model version."` See ``FamilySchemaV2`` for
    /// what freezing a version actually costs and when it becomes unavoidable.
    ///
    /// No CloudKit container is attached either. See ``zoneNote`` for why that
    /// is a deferral rather than a decision.
    public static func container(at url: URL? = nil) throws -> ModelContainer {
        let configuration =
            if let url {
                ModelConfiguration(schema: schema, url: url)
            } else {
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            }
        return try ModelContainer(for: schema, configurations: configuration)
    }

    /// An empty store that never touches disk. For tests.
    public static func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
    }

    /// **The custom-zone requirement, and what is actually true today.**
    ///
    /// The spec's invariant is that records live in a named custom CloudKit
    /// zone from the first release, because CloudKit cannot share the default
    /// zone and moving every record later is the expensive kind of migration.
    ///
    /// Two things about that are worth writing down rather than assuming:
    ///
    /// 1. SwiftData does not expose zone naming. Its CloudKit integration uses
    ///    one fixed custom zone. That satisfies *not the default zone*, which
    ///    is the part the migration risk actually rests on — but the zone is
    ///    not ours to name.
    /// 2. Whether that zone can be shared wholesale with
    ///    `CKRecordNameZoneWideShare` is unverified. It is the open question
    ///    Storage Stage 4 exists to answer, and the answer decides whether
    ///    sharing can stay on SwiftData or has to drop to
    ///    `NSPersistentCloudKitContainer` or hand-rolled CloudKit.
    ///
    /// What this schema does in the meantime is pay the compatibility costs
    /// that only get more expensive with data in them: stable UUIDs generated
    /// at creation, `modifiedAt` on every record, no reliance on insertion
    /// order or locally sequential identifiers, the family as an explicit
    /// record with its own id, every attribute defaulted and every
    /// relationship optional, and no unique constraints — CloudKit rejects
    /// those outright.
    ///
    /// Do not treat the zone invariant as satisfied because this compiles.
    public static let zoneNote = """
        v1 is local-only with no CloudKit container attached. Zone-wide sharing \
        of the zone SwiftData manages is unverified — see Storage and Data \
        Model, Stage 4.
        """
}
