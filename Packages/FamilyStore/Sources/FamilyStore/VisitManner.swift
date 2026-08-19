/// Kept though the shelf treats both alike — a future played-only filter needs it.
public enum VisitManner: String, Sendable, Codable, Hashable, CaseIterable {
    /// Navigated into a container: an album, an artist, a playlist.
    case opened

    /// Pressed play, and the engine allowed it.
    case played
}
