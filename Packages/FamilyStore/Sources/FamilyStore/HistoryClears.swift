import Foundation
import SwiftData

/// Device-local, never synced — losing it just re-applies clears, idempotently.
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

/// Pure — taking the max gives idempotency and order-independence for free.
public enum HistoryClears {
    /// Max, not newest-issued, so a clock skew can't undo a deliberate clear.
    public static func boundary(for kidID: UUID, in records: [HistoryClearRecord]) -> Date? {
        records
            .filter { $0.kidID == kidID }
            .map(\.clearedThrough)
            .max()
    }

    /// `nil` when caught up — strictly greater, so a re-run costs nothing.
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

/// Bounded to an instant, unlike ``Kid/deleteHistory`` — conflating over-deletes.
public enum HistoryClearApplier {
    /// Advances only after deletions save — a crash re-applies, never skips.
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

    /// Inclusive at `boundary`, matching `clearedThrough`: at or before it goes.
    @MainActor
    private static func clear(kidID: UUID, through boundary: Date, in context: ModelContext)
        -> Bool
    {
        var changed = false

        // Through the protocol, so a fifth event table can't be silently skipped.
        changed = purge(VisitEventRecord.self, kidID, boundary, context) || changed
        changed = purge(SearchEventRecord.self, kidID, boundary, context) || changed
        changed = purge(PlayEventRecord.self, kidID, boundary, context) || changed
        changed = purge(BlockEventRecord.self, kidID, boundary, context) || changed

        // Judged by period start — a straddling summary errs toward destruction.
        let summaries = fetch(WeeklySummaryRecord.self, kidID, context)
            .filter { $0.weekStart <= boundary }
        for row in summaries { context.delete(row) }
        changed = changed || !summaries.isEmpty

        // Deleted wholesale — a projection ``RecentsProjector`` rebuilds anyway.
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

    /// Filtered in Swift — a `#Predicate` across `Kid` is SwiftData's weak spot.
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

/// Lets ``HistoryClearApplier`` ask "whose is this" without a six-way switch.
protocol KidScoped: AnyObject {
    var kid: Kid? { get }
}

extension VisitEventRecord: KidScoped {}
extension SearchEventRecord: KidScoped {}
extension PlayEventRecord: KidScoped {}
extension BlockEventRecord: KidScoped {}
extension WeeklySummaryRecord: KidScoped {}
extension RecentTrailRecord: KidScoped {}
