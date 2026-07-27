/// How much of the catalog one kid can reach. Set per kid, not per family.
public enum SandboxMode: String, Sendable, Codable, Hashable, CaseIterable {
    /// Level 1. Nothing is reachable unless the parent put it, or something
    /// containing it, on the allow list. Search is hidden in the player.
    case allowOnly

    /// Level 2. The whole catalog is reachable except explicit content and
    /// anything the parent denied. The default mode.
    case denyPlusAuto

    /// Level 3. Everything is reachable. Activity is still logged — this is the
    /// same app with the walls taken down, not a separate mode.
    case reportOnly
}
