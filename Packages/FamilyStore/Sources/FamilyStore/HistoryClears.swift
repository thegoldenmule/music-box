import Foundation
import SwiftData

/// How far each kid's history has been cleared **on this device**.
///
/// **Device-local and never synced**, on the same shelf as `DeviceLibraryState`
/// and `ActingGrownUp`: it says what this device has already acted on, which is a
/// different fact on every device and would be actively wrong if handed to
/// another one. The instruction is what syncs — see ``HistoryClearRecord``.
///
/// Losing it is survivable in the direction that matters: an empty watermark makes
/// every clear look unapplied, so they are applied again, and applying a clear
/// twice deletes nothing the first pass left behind.
public protocol HistoryClearWatermarkStore: Sendable {
    func watermark(for kidID: UUID) -> Date?
    func setWatermark(_ date: Date, for kidID: UUID)
    func forget(_ kidID: UUID)
}

public struct UserDefaultsHistoryClearWatermark: HistoryClearWatermarkStore {
    public static let prefix = "com.thegoldenmule.auralsandbox.historyCleared."

    nonisolated(unsafe) private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ kidID: UUID) -> String { Self.prefix + kidID.uuidString }

    public func watermark(for kidID: UUID) -> Date? {
        defaults.object(forKey: key(kidID)) as? Date
    }

    public func setWatermark(_ date: Date, for kidID: UUID) {
        defaults.set(date, forKey: key(kidID))
    }

    public func forget(_ kidID: UUID) {
        defaults.removeObject(forKey: key(kidID))
    }
}

public final class InMemoryHistoryClearWatermark: HistoryClearWatermarkStore, @unchecked Sendable {
    private let lock = NSLock()
    private var marks: [UUID: Date] = [:]

    public init() {}

    public func watermark(for kidID: UUID) -> Date? { lock.withLock { marks[kidID] } }
    public func setWatermark(_ date: Date, for kidID: UUID) {
        lock.withLock { marks[kidID] = date }
    }
    public func forget(_ kidID: UUID) { lock.withLock { marks[kidID] = nil } }
}

// MARK: -

/// What a set of clear instructions adds up to.
///
/// **Pure, because the arithmetic is the whole design.** A ``HistoryClearRecord``
/// is a statement about a *range* rather than about rows — everything at or before
/// `clearedThrough` goes, whenever it turns up — and that is what makes it
/// idempotent, independent of arrival order, and effective against rows that had
/// not been written yet when it was issued. All three of those are properties of
/// taking a maximum, so taking the maximum is the part worth testing.
public enum HistoryClears {
    /// The furthest any instruction reaches for this kid, ignoring what has
    /// already been done.
    ///
    /// The maximum rather than the newest-issued: two parents clearing at once
    /// produce two rows, and the one that reaches further is the one that has to
    /// win. Picking by `issuedAt` would let a clock skew of a second undo a
    /// deliberate deletion.
    public static func boundary(for kidID: UUID, in records: [HistoryClearRecord]) -> Date? {
        records
            .filter { $0.kidID == kidID }
            .map(\.clearedThrough)
            .max()
    }

    /// How far this device still has to clear, or `nil` when it is up to date.
    ///
    /// **Strictly greater, so a re-run is free.** This is called on every launch
    /// and every sync pass, and a boundary equal to the watermark means the work
    /// was done — returning it anyway would delete nothing and write a row's worth
    /// of churn every time.
    public static func outstanding(
        for kidID: UUID,
        in records: [HistoryClearRecord],
        watermark: Date?
    ) -> Date? {
        guard let boundary = boundary(for: kidID, in: records) else { return nil }
        guard let watermark else { return boundary }
        return boundary > watermark ? boundary : nil
    }
}

// MARK: -

/// Carries out what ``HistoryClears`` decided.
///
/// **Separate from the decision for the usual reason**, and separate from
/// ``Kid/deleteHistory(at:)`` because that one is unbounded: a parent tapping
/// "clear the logs" means everything, while an instruction arriving from another
/// device means everything *up to an instant* and must leave the rows written since
/// alone. Conflating them would have a clear issued last Tuesday, arriving today,
/// delete a week of a child's listening nobody asked about.
public enum HistoryClearApplier {
    /// Applies every outstanding instruction and advances the watermark.
    ///
    /// Returns the kids whose rows actually changed, which is what a caller needs
    /// in order to know whether anything on screen is now stale.
    ///
    /// **The watermark advances only after the deletions are saved.** A crash
    /// between the two has to leave the clear looking unapplied, because the
    /// direction that fails safely is doing it twice.
    @MainActor
    @discardableResult
    public static func apply(
        for kids: [UUID],
        in context: ModelContext,
        watermarks: any HistoryClearWatermarkStore
    ) -> [UUID] {
        let records = (try? context.fetch(FetchDescriptor<HistoryClearRecord>())) ?? []
        guard !records.isEmpty else { return [] }

        var touched: [UUID] = []
        for kidID in kids {
            guard
                let boundary = HistoryClears.outstanding(
                    for: kidID, in: records, watermark: watermarks.watermark(for: kidID))
            else { continue }

            let changed = clear(kidID: kidID, through: boundary, in: context)
            guard (try? context.save()) != nil else { continue }
            watermarks.setWatermark(boundary, for: kidID)
            if changed { touched.append(kidID) }
        }
        return touched
    }

    /// Deletes one kid's rows at or before `boundary`.
    ///
    /// `at <= boundary`, inclusive, matching `clearedThrough`'s own wording:
    /// *everything at or before this instant is to be destroyed*.
    @MainActor
    private static func clear(kidID: UUID, through boundary: Date, in context: ModelContext)
        -> Bool
    {
        var changed = false

        // The four event tables, once, through the protocol that exists so this is
        // not written four times — and so that a fifth event table fails to
        // conform rather than being silently left behind by a deletion a parent
        // asked for.
        changed = purge(VisitEventRecord.self, kidID, boundary, context) || changed
        changed = purge(SearchEventRecord.self, kidID, boundary, context) || changed
        changed = purge(PlayEventRecord.self, kidID, boundary, context) || changed
        changed = purge(BlockEventRecord.self, kidID, boundary, context) || changed

        // **A summary containing any cleared data goes**, judged on the start of
        // the period rather than its end. One outliving the events it was derived
        // from is a record the parent asked us to destroy, and a summary that
        // straddles the boundary is partly made of them — so the direction that
        // errs toward destruction is the one the instruction asked for.
        let summaries = fetch(WeeklySummaryRecord.self, kidID, context)
            .filter { $0.weekStart <= boundary }
        for row in summaries { context.delete(row) }
        changed = changed || !summaries.isEmpty

        // **The shelf goes wholesale rather than by date, and that is correct
        // rather than lazy.** It is a projection over the visits just deleted;
        // `RecentsProjector` recomputes it unconditionally and will rebuild it from
        // whatever survived. Deleting entries by their own timestamps would leave a
        // trail that disagrees with the visits it is supposed to be derived from.
        let trail = fetch(RecentTrailRecord.self, kidID, context)
        for row in trail { context.delete(row) }
        changed = changed || !trail.isEmpty

        return changed
    }

    @MainActor
    private static func purge<T: PersistentModel & ExportableEvent>(
        _ type: T.Type, _ kidID: UUID, _ boundary: Date, _ context: ModelContext
    ) -> Bool {
        let doomed = fetch(type, kidID, context).filter { $0.at <= boundary }
        for row in doomed { context.delete(row) }
        return !doomed.isEmpty
    }

    /// Every row of a kid-scoped type belonging to this kid.
    ///
    /// Fetched unfiltered and narrowed in Swift rather than by `#Predicate`,
    /// because the relationship to `Kid` is what carries the ownership and a
    /// predicate across it is the shape SwiftData is least reliable about. These
    /// tables are large; this runs at most once per kid per clear, which is the
    /// trade being made knowingly.
    @MainActor
    private static func fetch<T: PersistentModel>(
        _ type: T.Type, _ kidID: UUID, _ context: ModelContext
    ) -> [T] {
        let all = (try? context.fetch(FetchDescriptor<T>())) ?? []
        return all.filter { row in
            (row as? any KidScoped)?.kid?.id == kidID
        }
    }
}

/// Rows that belong to one child.
///
/// Exists so ``HistoryClearApplier`` can ask "whose is this" without a switch over
/// six classes. Deliberately not `ExportableEvent`: the summary and the trail are
/// not events and are cleared for different reasons.
protocol KidScoped: AnyObject {
    var kid: Kid? { get }
}

extension VisitEventRecord: KidScoped {}
extension SearchEventRecord: KidScoped {}
extension PlayEventRecord: KidScoped {}
extension BlockEventRecord: KidScoped {}
extension WeeklySummaryRecord: KidScoped {}
extension RecentTrailRecord: KidScoped {}
