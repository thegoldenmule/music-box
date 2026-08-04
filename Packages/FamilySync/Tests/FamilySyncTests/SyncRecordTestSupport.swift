@testable import FamilyStore

/// A row's record, for tests that build a well-formed one and want to say so.
///
/// `syncRecord()` is optional in production because an orphaned row cannot name
/// itself — see ``SyncEncodable/syncRecordName``. Almost every test here
/// constructs a properly parented row, so unwrapping at 50 call sites would say
/// nothing except that the test set it up correctly. The tests that care about
/// the nil case ask for `syncRecord()` directly.
extension SyncEncodable {
    var record: SyncedRecord {
        guard let record = syncRecord() else {
            fatalError("\(Self.syncRecordType) could not name itself — orphaned in a test fixture?")
        }
        return record
    }
}
