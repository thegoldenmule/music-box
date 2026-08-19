/// Distinguishes "tried to play" from "filtered before they saw it" — same row.
public enum BlockReach: String, Sendable, Codable, Hashable, CaseIterable {
    /// Filtered out before it was drawn — the kid never saw it.
    case unseen

    /// The kid acted on it — pressed play, hearted, or added to a playlist.
    case reached
}
