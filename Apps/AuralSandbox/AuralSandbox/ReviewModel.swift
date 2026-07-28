import CatalogKit
import FamilyStore
import Foundation
import KidLibrary
import PolicyEngine

/// How far back one screenful of a kid's history reaches.
///
/// **Always bounded**, including the widest one. An open-ended window is a fetch
/// with no limit over the largest table in the store, and "everything" a parent
/// means is never literally everything.
enum ReviewRange: String, CaseIterable, Identifiable {
    case week
    case month
    case everything

    var id: String { rawValue }

    var label: String {
        switch self {
        case .week: "This week"
        case .month: "This month"
        case .everything: "Everything"
        }
    }

    func interval(endingAt now: Date) -> DateInterval {
        let days: Double =
            switch self {
            case .week: 7
            case .month: 30
            case .everything: 365 * 5
            }
        return DateInterval(start: now.addingTimeInterval(-days * 86_400), end: now)
    }
}

/// Everything the parent's review screen reads, in one place.
///
/// The screen never touches the store, the catalog or a provider directly. That
/// keeps the one rule this component turns on — **nothing here is filtered by
/// policy** — a property of the two seams below it, ``ReviewReader`` and
/// ``MergedLibrary/reviewed()``, rather than a thing each view has to remember.
///
/// Loading is deliberately in two passes. The first is local and complete: every
/// row a parent reads renders from strings copied at write time, with no network
/// call anywhere in it. The second is best-effort and only improves labels. A
/// report has to work on a plane.
@MainActor
@Observable
final class ReviewModel {
    private let session: Session
    private(set) var kid: Kid

    var range: ReviewRange = .week {
        didSet { if range != oldValue { reload() } }
    }

    private(set) var isLoading = false
    private(set) var failure: String?

    private(set) var window: ReviewWindow?
    private(set) var summary: WeeklySummary?

    /// Plays and blocks with today's verdict attached. The stored fact and the
    /// annotation are separate values on purpose: one is history, the other is a
    /// fresh question, and a screen that merged them would be claiming the past
    /// changed.
    private(set) var plays: [Annotated<PlayEvent>] = []
    private(set) var blocks: [Annotated<ReviewedBlock>] = []
    private(set) var groups: [BlockGroup] = []

    private(set) var library: ReviewedLibrary?

    /// Names for identifiers the log stores without one. Filled by the second
    /// pass; empty is a perfectly good state.
    private(set) var names: [CatalogID: String] = [:]
    private(set) var kidPlaylistNames: [UUID: String] = [:]

    init(session: Session, kid: Kid) {
        self.session = session
        self.kid = kid
    }

    func show(_ kid: Kid) {
        guard kid.id != self.kid.id else { return }
        self.kid = kid
        reload()
    }

    func reload() {
        Task { await load() }
    }

    // MARK: - Loading

    func load() async {
        isLoading = true
        defer { isLoading = false }

        let kidID = kid.id
        let interval = range.interval(endingAt: .now)
        let reader = session.review

        do {
            let window = try await reader.window(for: kidID, in: interval)
            let policy = try await reader.policy(for: kidID)
            let engine = PolicyEngine(policy: policy)
            let heard = try await reader.previouslyHeard(for: kidID, before: interval.start)
            kidPlaylistNames = try await reader.kidPlaylistNames(for: kidID)

            self.window = window
            plays = window.plays.map { ReviewAnnotator.annotate($0, knowing: $0.knowledge, with: engine) }
            blocks = window.blocks.map {
                ReviewAnnotator.annotate($0, knowing: $0.event.knowledge, with: engine)
            }
            groups = BlockGroup.group(window.blocks)
            summary = WeeklySummary.of(window, previouslyHeard: heard)
            failure = nil
        } catch {
            failure = Session.message(for: error)
            return
        }

        // Second pass. Everything above already rendered.
        await loadLibrary()
        await loadNames()
    }

    private func loadLibrary() async {
        library = await session.reviewLibrary(for: kid).reviewed()
    }

    /// Fills in names for artists and containers the log knows only by
    /// identifier.
    ///
    /// A block row keeps an artist *identifier* and its own title, so without
    /// this a group of one artist's tracks is labelled with whichever song was
    /// blocked most recently — technically true and useless to read.
    private func loadNames() async {
        var wanted = Set(groups.compactMap(\.artistID))
        for play in plays {
            switch play.fact.origin {
            case .browse(let id), .playlist(let id): wanted.insert(id)
            default: break
            }
        }
        for block in blocks {
            switch block.fact.event.origin {
            case .browse(let id), .playlist(let id): wanted.insert(id)
            default: break
            }
        }
        guard !wanted.isEmpty else { return }
        names = await session.names(for: Array(wanted))
    }

    // MARK: - Reading

    /// The label for a block group: the artist's real name once it is known.
    func title(of group: BlockGroup) -> String {
        group.artistID.flatMap { names[$0] } ?? group.displayName
    }

    func described(_ origin: PlaybackOrigin) -> OriginDescription {
        origin.described(
            kidPlaylistName: { [kidPlaylistNames] in kidPlaylistNames[$0] },
            catalogName: { [names] in names[$0] }
        )
    }

    // MARK: - Acting

    /// Allow or deny, from a report row. Awaited, and its failure surfaced.
    ///
    /// The report is **not** rewritten: past blocks keep the reason that
    /// produced them. Only the annotation changes, which is why this reloads.
    func add(_ kind: PolicyEntry.Kind, id: CatalogID, displayName: String) {
        if let message = session.addEntry(for: kid, kind: kind, id: id, displayName: displayName) {
            failure = message
            return
        }
        reload()
    }

    func clearFailure() { failure = nil }

    func deleteHistory() {
        if let message = session.deleteHistory(for: kid) {
            failure = message
            return
        }
        reload()
    }

    func deleteEverything() {
        Task {
            if let message = await session.deleteEverything(for: kid) {
                failure = message
                return
            }
            await load()
        }
    }
}
