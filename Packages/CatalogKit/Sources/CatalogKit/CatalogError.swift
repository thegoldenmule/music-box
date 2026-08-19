import Foundation

// Re-exported so callers need no second import for CatalogID/ContentRating.
@_exported import PolicyEngine

/// Named cases the UI can act on — a raw MusicKit error just reads as our bug.
public enum CatalogError: Error, Sendable, Hashable {
    /// The user has not granted access to Apple Music, or revoked it in Settings.
    case notAuthorized(AuthorizationStatus)

    /// No active Apple Music subscription, so nothing will play.
    case noSubscription

    /// Library off, not empty — distinct cases, and the fix is in Settings.
    case cloudLibraryDisabled

    /// No network means the app doesn't work — MusicKit has no download story.
    case offline

    /// Blocked outside (Screen Time, parental controls) — explain, don't own it.
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
