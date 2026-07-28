/// How the kid got to something.
///
/// The Recent shelf treats both the same — arriving is arriving. The column is
/// here anyway, because "show only what they actually played" is a rule that
/// cannot be built later out of rows that never said which this was, and because
/// a parent reading *opened this artist's page* and *played one of their tracks*
/// is not reading the same fact about their child.
///
/// Compare ``BlockReach``, which records the same distinction from the other
/// side: a `BlockEvent` with `reach == .reached` is the row that exists *instead
/// of* this one when the engine refused. Nothing ever writes both.
public enum VisitManner: String, Sendable, Codable, Hashable, CaseIterable {
    /// Navigated into a container: an album, an artist, a playlist.
    case opened

    /// Pressed play, and the engine allowed it.
    case played
}
