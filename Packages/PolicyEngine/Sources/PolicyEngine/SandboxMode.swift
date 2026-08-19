/// How much of the catalog one kid can reach. Set per kid, not per family.
public enum SandboxMode: String, Sendable, Codable, Hashable, CaseIterable {
    /// Level 1: only what the parent added; open search is hidden.
    case allowOnly

    /// Level 2: whole catalog minus explicit and parent denies. The default.
    case denyPlusAuto

    /// Level 3: everything reachable; same app, walls down, still logged.
    case reportOnly
}
