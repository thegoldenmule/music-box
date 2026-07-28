import CatalogKit
import Observation
import SwiftUI

/// Everywhere the kid's stack can go.
///
/// One type rather than two, and that is the whole reason it exists. A
/// `NavigationPath` swallows anything `Hashable` and hands nothing back — it can
/// be counted and popped, never read — so a stack built on one cannot answer
/// "is this album already open?" and therefore cannot refuse to open it twice.
/// A typed array can.
///
/// The two cases are the two unrelated things this stack pushes: a container the
/// kid browsed into, and a screen that is not browsing.
enum KidRoute: Hashable {
    case container(CatalogItem)
    case home(HomeRoute)
}

/// The kid stack's path, in a box other screens can reach — and the one place
/// that decides what the stack is allowed to look like.
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
    private var steps: [KidRoute] = []

    /// What the `NavigationStack` is bound to.
    ///
    /// **The setter is the dedupe, and it has to be the setter.** A
    /// `NavigationLink` appends to this binding itself — it never calls
    /// ``open(_:)`` — so a rule enforced only in the push method would cover the
    /// now-playing screen and miss every tile, chip and shelf in the app.
    /// Collapsing here catches all of them, before the stack is rebuilt, so
    /// there is no push-then-pop to watch.
    var path: [KidRoute] {
        get { steps }
        set { steps = Self.collapsed(newValue) }
    }

    /// Opens a container, closing whatever was covering the stack.
    ///
    /// The dismissal is asked for by the caller, not here — this type knows
    /// about the path and deliberately nothing about who is on top of it.
    func open(_ item: CatalogItem) {
        path.append(.container(item))
    }

    /// The same screen never appears twice.
    ///
    /// Reaching a screen that is already open **unwinds to it** rather than
    /// stacking a copy: everything above the existing one is dropped and the
    /// kid lands on the page that was already there. The alternative — refusing
    /// the push outright — leaves them staring at the screen they just tried to
    /// leave, which reads as a broken tap.
    ///
    /// The case that made this necessary: open an album, play it, open the
    /// now-playing screen, tap the cover. The album is *already* the top of the
    /// stack, and without this the kid gets a second identical album page and a
    /// back button that goes to the same album again. Two taps of that and the
    /// way out is three screens deep.
    ///
    /// It also catches the honest loops — an artist's album crediting the artist
    /// you came from, a playlist reached from a song that is on it — where every
    /// step was reasonable and the stack still grew a cycle.
    static func collapsed(_ route: [KidRoute]) -> [KidRoute] {
        var kept: [KidRoute] = []
        for step in route {
            if let already = kept.firstIndex(of: step) {
                // Unwind to the one that is already open. Nothing is appended:
                // the existing entry *is* this step.
                kept.removeSubrange((already + 1)...)
            } else {
                kept.append(step)
            }
        }
        return kept
    }
}
