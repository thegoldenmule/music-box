import Foundation

/// Who is at the screen; with the device answers, the whole of which providers open.
public enum LibraryAudience: Sendable, Hashable {
    /// The kid: our store always, the Apple library only if it's their own.
    case kid

    /// A grown-up behind the passcode: the Apple library alone, walls down.
    case grownUp
}

/// One table for the gate and the admin's health line, so they can't disagree.
public enum LibraryLiveness: Sendable, Hashable {
    /// Read from and, capability permitting, written to.
    case live

    /// Written to but not yet read from — onboarding hasn't asked.
    case notReadable(ProviderHealth.Reason)

    /// Neither, and the reason is an answer someone gave, not a fault.
    case notLive(ProviderHealth.Reason)

    public var isLive: Bool {
        if case .notLive = self { return false }
        return true
    }

    public var isReadable: Bool { self == .live }

    public static func status(
        of id: LibraryProviderID,
        device: DeviceLibraryState,
        audience: LibraryAudience
    ) -> LibraryLiveness {
        switch (audience, id) {
        // A grown-up's shelf is their library and nothing of the kid's, whatever
        // the device answers say: the answers describe whose library this is,
        // and the grown-up just said it's theirs by unlocking.
        case (.grownUp, .appleMusic): .live
        case (.grownUp, .cloudKit): .notLive(.grownUpMode)

        case (.kid, .cloudKit): .live
        case (.kid, .appleMusic):
            if device.isSharedDevice {
                .notLive(.sharedDevice)
            } else if !device.hasBeenAsked {
                .notReadable(.notYetAsked)
            } else {
                .live
            }
        }
    }
}
