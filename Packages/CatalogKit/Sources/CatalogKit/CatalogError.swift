import Foundation

// Re-exported so callers need no second import for `CatalogID`, `ContentRating`,
// `Verdict` — every type this layer's public API is written in terms of.
@_exported import PolicyEngine

/// Things that go wrong, in terms the UI can act on. Several of these are not
/// our bug but will be reported as our bug; a raw MusicKit error surfaced to a
/// parent is a support ticket, a named case is a sentence we can write.
public enum CatalogError: Error, Sendable, Hashable {
    /// The user has not granted access to Apple Music, or revoked it in Settings.
    case notAuthorized(AuthorizationStatus)

    /// No active Apple Music subscription, so nothing will play.
    case noSubscription

    /// iCloud Music Library is off, so library reads return nothing. Distinct
    /// from an empty library, and the fix is in Settings.
    case cloudLibraryDisabled

    /// No network. There is no download story under the MusicKit terms, so this
    /// means the app does not work rather than degrading.
    case offline

    /// Playback was refused by something outside this app — Screen Time's music
    /// restriction, or Apple Music's parental controls. Its own case because a
    /// restriction set elsewhere, possibly months ago, surfaces here confusingly;
    /// explain it and point at the setting rather than reading as our refusal.
    case restrictedOutsideApp

    /// The item is gone from the catalog. Allow lists have to survive this.
    case itemUnavailable(CatalogID)

    /// Anything else, kept so the underlying error is not lost.
    case underlying(String)
}

extension CatalogError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            "Aural Sandbox needs permission to use Apple Music."
        case .noSubscription:
            "This account doesn't have an active Apple Music subscription."
        case .cloudLibraryDisabled:
            "Sync Library is turned off, so this account's music isn't available."
        case .offline:
            "Aural Sandbox needs an internet connection to play music."
        case .restrictedOutsideApp:
            "Something outside this app is blocking this — check Screen Time's music restriction and Apple Music's parental controls."
        case .itemUnavailable:
            "This isn't available on Apple Music anymore."
        case .underlying(let message):
            message
        }
    }
}
