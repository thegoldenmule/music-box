import Foundation
import SwiftData

/// v1 is local-only — a legal position, not a preference, given a child's history.
public enum FamilyStore {
    /// Lives in `FamilySchemaV2` so the version id and its models can't drift apart.
    public static let schema = Schema(versionedSchema: FamilySchemaV2.self)

    /// No migration plan — one naming live types goes stale the moment they change.
    public static func container(at url: URL? = nil) throws -> ModelContainer {
        let configuration =
            if let url {
                ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            } else {
                ModelConfiguration(
                    schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
            }
        return try ModelContainer(for: schema, configurations: configuration)
    }

    /// An empty store that never touches disk. For tests.
    public static func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(
                schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    /// Not a formality: the iCloud entitlement once silently enabled mirroring.
    public static let mirroringNote = """
        cloudKitDatabase is .none explicitly. The default is .automatic, which \
        enables mirroring as soon as the app carries an iCloud entitlement — \
        and sixteen to-many relationships are non-optional, which mirroring \
        rejects outright.
        """

    /// SwiftData's fixed zone, not the spec's named one — sharability unverified.
    public static let zoneNote = """
        v1 is local-only with no CloudKit container attached. Zone-wide sharing \
        of the zone SwiftData manages is unverified — see Storage and Data \
        Model, Stage 4.
        """
}
