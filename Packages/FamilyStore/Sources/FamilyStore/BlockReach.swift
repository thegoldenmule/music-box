/// Whether the kid ever saw the thing that was blocked.
///
/// Both block paths write the same row otherwise: a result filtered out of a
/// search page and a song the kid pressed play on carry the same identifier, the
/// same reason and the same `origin: .search(term:)`. Nothing else stored tells
/// them apart, and for a parent they are not the same fact at all —
///
/// > *Your child tried to play a song called ——.*
/// >
/// > *A song called —— appeared in a page of results we filtered before they
/// > saw it.*
///
/// The second is far more common: the over-fetch loop discards a multiple of
/// every page, and each discard is a row. Without this column a report either
/// invents intent the kid never had, or buries the few rows that describe real
/// intent under everything else.
///
/// **Two cases and not three, only because nothing has shipped.** With rows
/// already on a device there would have to be an `unknown` for the ones written
/// before the column existed — the same reasoning that makes
/// ``PlaybackOrigin/init(stored:)`` return `nil` rather than claiming everything
/// came from the home screen.
///
/// This is the one field on a block row that describes the *child*. Everything
/// else on it is about the item or the rule.
public enum BlockReach: String, Sendable, Codable, Hashable, CaseIterable {
    /// Filtered out of a batch before it was drawn. The kid never saw it and did
    /// nothing.
    case unseen

    /// The kid acted on it: pressed play, tapped the heart, added it to a
    /// playlist.
    case reached
}
