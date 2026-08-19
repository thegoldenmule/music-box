@testable import FamilyStore

/// Force-unwraps `syncRecord()` — nil cases here ask for that directly instead.
extension SyncEncodable {
    var record: SyncedRecord {
        guard let record = syncRecord() else {
            fatalError("\(Self.syncRecordType) could not name itself — orphaned in a test fixture?")
        }
        return record
    }
}
