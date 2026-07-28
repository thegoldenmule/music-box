import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

/// Artwork, held in memory and only in memory.
///
/// **Memory only is a licence position, not a performance choice.** The
/// Developer Program License Agreement §3.3.6(D) says you may not "download,
/// upload or modify any MusicKit Content", and the app's standing rule is that
/// artwork bytes are never copied into our storage — only the URL is. A
/// transient in-memory copy is the ordinary mechanics of drawing a picture on a
/// screen; a file on disk is a download. So the session below is configured with
/// no URL cache at all, and nothing here ever touches the filesystem.
///
/// That is a change in the app's favour rather than a new risk. `AsyncImage`,
/// which this replaces, loads through `URLSession.shared` and therefore through
/// `URLCache.shared` — which has a **disk** capacity by default. Every tile the
/// kid scrolled past was being written to disk by the URL loading system.
///
/// **Why it exists at all**: `AsyncImage` holds nothing between appearances, so
/// every tile scrolled off and back on was a fresh request, and the same album
/// cover was fetched once for the shelf, again for the bar, and again for the
/// full-screen player. Twenty-four tiles at 512 points square, six connections
/// to the host, and no memory of any of it is why artwork "sometimes" did not
/// appear: a request that failed or was cancelled had nothing behind it and
/// `AsyncImage` never asks twice.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    /// `NSCache` rather than a dictionary, for the eviction: it drops its
    /// contents under memory pressure without being asked, which is exactly the
    /// behaviour wanted from something holding decoded bitmaps on a phone.
    private let store = NSCache<NSURL, Entry>()

    /// One request per URL, however many views want it. A grid, the bar and the
    /// full-screen player all asking for the same cover at once is the common
    /// case, not the rare one.
    private var inFlight: [URL: Task<PlatformImage?, Never>] = [:]

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        // The point of the whole type. `ephemeral` already keeps its cache off
        // disk; setting it to nil says so out loud and survives someone
        // switching the base configuration to `.default` later.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Shorter than the 60-second default so a stalled request fails while
        // the kid is still looking at the screen, in time for the retry below to
        // mean something.
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)

        // Roughly sixty 512-point covers decoded. Advisory — `NSCache` treats
        // the limit as a hint and evicts under pressure regardless.
        store.totalCostLimit = 64 * 1024 * 1024
    }

    /// What is already in hand, for a view that is drawing right now.
    ///
    /// Synchronous so a cache hit renders in the first layout pass. Going
    /// through the async path for something already decoded would show the
    /// placeholder for a frame, which is the flicker this type exists to remove.
    func cached(_ url: URL) -> PlatformImage? {
        store.object(forKey: url as NSURL)?.image
    }

    func image(for url: URL) async -> PlatformImage? {
        if let hit = cached(url) { return hit }

        if let running = inFlight[url] { return await running.value }

        let task = Task { [session] in
            await Self.fetch(url, using: session)
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil

        // **Failures are not cached.** A missing entry is the difference between
        // "this artist has no picture" and "that request did not work", and only
        // the second one should be tried again when the tile next appears.
        if let image {
            store.setObject(Entry(image), forKey: url as NSURL, cost: image.cacheCost)
        }
        return image
    }

    /// Off the main actor: the download and, more to the point, the decode.
    ///
    /// Decoding a 512-point cover is a millisecond or two, which is nothing once
    /// and a visible stutter twenty-four times while a shelf scrolls.
    ///
    /// Handing the result back to the main actor needs no `Sendable` promise
    /// about `UIImage` or `NSImage` — neither makes one, and `NSImage` genuinely
    /// is not. Region-based isolation is what makes it legal: the image is
    /// created here, nothing else ever holds it, so the compiler can see the
    /// whole region move across in one piece.
    ///
    /// One retry, because the failure this fixes is a transient one — a
    /// cancelled connection, a slot that came free late. A second failure is
    /// treated as an answer and the placeholder stands.
    private nonisolated static func fetch(
        _ url: URL,
        using session: URLSession
    ) async -> PlatformImage? {
        for attempt in 0..<2 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(400))
            }
            if Task.isCancelled { return nil }

            guard let (data, response) = try? await session.data(from: url) else { continue }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                // A 404 on a storefront URL is an answer, not a hiccup. Retrying
                // it just delays the placeholder.
                return nil
            }
            if let decoded = PlatformImage(data: data) { return decoded }
        }
        return nil
    }

    /// A box, because `NSCache` holds objects and `PlatformImage` is one but the
    /// generic parameter has to be a class this file owns to attach a cost to.
    private final class Entry {
        let image: PlatformImage
        init(_ image: PlatformImage) { self.image = image }
    }
}

extension PlatformImage {
    /// Bytes the decoded bitmap occupies, near enough for a cache limit.
    fileprivate var cacheCost: Int {
        #if canImport(UIKit)
        Int(size.width * scale * size.height * scale) * 4
        #else
        Int(size.width * size.height) * 4
        #endif
    }
}

extension Image {
    init(platform image: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: image)
        #else
        self.init(nsImage: image)
        #endif
    }
}

/// ``AsyncImage``'s shape, backed by ``ArtworkCache``.
///
/// Deliberately the same two closures in the same order, so a call site changes
/// by its type name alone and every bit of the styling around it — the aspect
/// ratio, the clip shape, the placeholder glyph — stays where it was.
///
/// The one behavioural difference that is not the cache: this keeps its image
/// across a redraw. `AsyncImage` restarts its load whenever SwiftUI rebuilds it,
/// which in a `LazyVGrid` is often, and each restart is a chance to end up on
/// the placeholder for good.
struct ArtworkImage<Content: View, Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var content: (Image) -> Content
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var loaded: PlatformImage?

    /// The cache is consulted during the draw, not only in the task, so
    /// something already in memory never shows a placeholder first.
    private var image: PlatformImage? {
        loaded ?? url.flatMap { ArtworkCache.shared.cached($0) }
    }

    var body: some View {
        Group {
            if let image {
                content(Image(platform: image))
            } else {
                placeholder()
            }
        }
        // Keyed to the URL: a row recycled onto a different song has to drop the
        // last one's cover rather than keep drawing it under a new title.
        .task(id: url) {
            loaded = nil
            guard let url else { return }
            loaded = await ArtworkCache.shared.image(for: url)
        }
    }
}
