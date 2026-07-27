#if canImport(MusicKit)

import MusicKit

/// Authorization and subscription state, from MusicKit.
public struct MusicKitAccess: CatalogAccess {
    public init() {}

    public func requestAuthorization() async -> AuthorizationStatus {
        AuthorizationStatus(await MusicAuthorization.request())
    }

    public var authorizationStatus: AuthorizationStatus {
        AuthorizationStatus(MusicAuthorization.currentStatus)
    }

    public func subscriptionState() async throws -> SubscriptionState {
        do {
            return SubscriptionState(try await MusicSubscription.current)
        } catch {
            throw CatalogError.underlying(error.localizedDescription)
        }
    }

    public var subscriptionUpdates: AsyncStream<SubscriptionState> {
        AsyncStream { continuation in
            let task = Task {
                for await subscription in MusicSubscription.subscriptionUpdates {
                    continuation.yield(SubscriptionState(subscription))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension AuthorizationStatus {
    init(_ status: MusicAuthorization.Status) {
        self = switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .authorized: .authorized
        @unknown default: .notDetermined
        }
    }
}

extension SubscriptionState {
    init(_ subscription: MusicSubscription) {
        self.init(
            canPlayCatalogContent: subscription.canPlayCatalogContent,
            canBecomeSubscriber: subscription.canBecomeSubscriber,
            hasCloudLibraryEnabled: subscription.hasCloudLibraryEnabled
        )
    }
}

#endif
