import CatalogKit
import Observation
import SwiftUI

/// The kid stack's path, in a box other screens can reach.
///
/// Everything a kid browses into is pushed onto the one `NavigationStack` in
/// ``KidHomeView``, and a `NavigationLink` is enough for anything drawn inside
/// it. ``NowPlayingView`` is the exception: it is presented modally, so it sits
/// *outside* the stack and a link from it has nothing to push onto.
///
/// Handing the path down through the seven screens that draw a
/// ``NowPlayingBar`` would mean an initializer parameter on each, so it travels
/// in the environment instead — a modal inherits the environment of the view
/// that presented it, which is exactly the reach that is needed and no more.
///
/// **Not a way around the rules.** Everything this opens is a `CatalogItem` the
/// policy engine already allowed, and the screen it lands on filters its own
/// contents again on arrival.
@MainActor
@Observable
final class KidRouter {
    var path = NavigationPath()

    /// Opens a container, closing whatever was covering the stack.
    ///
    /// The dismissal is asked for by the caller, not here — this type knows
    /// about the path and deliberately nothing about who is on top of it.
    func open(_ item: CatalogItem) {
        path.append(item)
    }
}
