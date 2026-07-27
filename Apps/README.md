# Apps

App targets live here. Nothing yet.

Planned: `AuralSandbox`, one Xcode project with iOS and Mac destinations sharing
a SwiftUI codebase. It needs an Xcode project rather than a bare SwiftPM
executable because of entitlements, signing, the MusicKit capability, and the
background audio mode in Info.plist.

Blocked on enabling MusicKit for the App ID (Developer portal → Identifiers →
App Services → MusicKit). Nothing that touches Apple Music runs until that is on.
