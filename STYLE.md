# STYLE.md

How this app should look and move, and where Apple says so.

**This file is hand-maintained, like `CLAUDE.md`, and is the one other exception
to the wiki rule.** It is not generated from the wiki and editing it here is
correct. Design *specs* still live in the wiki (`ws:ms3de17i-0024-ik1oty`); this
is the layer below them — the house style, the availability floor arithmetic,
and the recipes for the set-pieces this app has decided it wants.

Everything below was verified on 2026-08-01 against the installed SDK, or fetched
from `developer.apple.com`, or compiled. Where something is a guess, it says so.

---

## 0. The short version

Nine things, in the order they pay off. Detail for each is further down.

| # | Change | Tier | Why it is first |
| --- | --- | --- | --- |
| 1 | **One accent colour** (three colour sets) | Floor | `Assets.xcassets` has only `AppIcon`. Every `.tint` in the app is stock system blue. This is the single cheapest change that stops the app reading as a template. |
| 2 | **One motion vocabulary** (`enum Motion`) | Floor | Nine animation sites, five distinct curves, no shared names, and eight of the nine are easing. Springs are interruptible; `.easeInOut(duration:)` is not. |
| 3 | **Symbol transitions + press feedback** | Floor | `.contentTransition(.symbolEffect(.replace))` and a pressed-state `ButtonStyle`. Two modifiers each, felt on every tap. |
| 4 | **Artwork at the right resolution** | Floor | `artworkSize: 512` feeds a 420pt hero — ~1260px of target from 512px of source. The kid's full-screen album art is soft, and the 56pt row thumb decodes a 512px bitmap. Both ends wrong. |
| 5 | **Dynamic Type + hit targets** | Floor | **Observed, not predicted:** at AX5 the shelf's fixed `.frame(height:)` makes the *artwork collapse to a thumbnail* while text takes the tile. Plus four `.font(.system(size:))` and 28pt controls where HIG's *default* is 44. |
| 6 | **Scroll behaviour on the shelves** | Floor | `.scrollTargetBehavior(.viewAligned)` + `.contentMargins`. Every first-party shelf snaps; these do not. |
| 7 | **Title hand-off on Album/Artist** | Floor | Those screens force `.inline` *and* have an empty bar, so scrolling past the cover leaves the screen with no name anywhere. |
| 8 | **The floating capsule bottom chrome** | Gated | The look the request actually described. Also deletes the double-`.bar` compositing defect. |
| 9 | **The artwork morph** | Floor | The 56pt thumb growing into the hero. Hardest, highest ceiling, and the only thing here that is genuinely novel work. |

**1–7 need no `#available` fence at all.** That is the headline finding of this
whole exercise: most of what separates this app from a current first-party app is
available at iOS 17 / macOS 14, the floor this project already stands on.

---

## 1. Ground truth

### Toolchain and floor

| | |
| --- | --- |
| Xcode | 26.6 (build 17F113) |
| SDKs installed | iOS 26.5, macOS 26.5 |
| Deployment floor | iOS 17.0, macOS 14.0 — **cannot be raised** |
| Swift | 6 language mode |
| `UIDesignRequiresCompatibility` | **absent** |

That last row is the one nobody chose. Because the app links against the iOS 26
SDK and does not opt out, **every standard component already renders in Liquid
Glass on iOS 26 / macOS 26** — navigation bars, toolbars, sheets, `Button`,
`List`, `Form`, `Slider`, window corners. On iOS 17–18 the same binary renders in
that OS's own design. Two looks, one codebase, no flag to flip.

Do not add the opt-out key. It is documented as temporary, and it is reported to
be removed in Xcode 27 — adopting it buys one release of debt.

### The three tiers

Every recommendation in this file is tagged with one of these. Getting the tier
wrong is a build failure, not a style disagreement (§7 proves it).

**Floor — iOS 17.0 / macOS 14.0. No fence.**
`.contentTransition(.symbolEffect(.replace))` · `.symbolEffect(_:value:)` ·
`.scrollTargetBehavior(.viewAligned)` · `.scrollTargetLayout()` ·
`.contentMargins(_:_:for:)` · `.scrollTransition(_:axis:transition:)` ·
`.visualEffect { }` · `.containerRelativeFrame(_:)` · `ContentUnavailableView` ·
`.spring(duration:bounce:)` · `.smooth` / `.snappy` / `.bouncy` ·
`.interactiveSpring` · `Spring` · `.scrollBounceBehavior` ·
`.scrollIndicators` · `Button(_:systemImage:action:)` · `.contentShape(.rect)` ·
generated asset symbols (`Color.kidAccent`)

**Already below the floor**, so equally free: `Material` (iOS 15) ·
`.fontDesign(_:)` (iOS 16.1) · `@ScaledMetric` (iOS 14) ·
`onGeometryChange(for:of:action:)` single-value overload (iOS 16) ·
`UnevenRoundedRectangle` (iOS 16) · `AnyShape` (iOS 16) ·
`.toolbarBackground(_:for:)` (iOS 16) · `.badge` (iOS 15) ·
`.redacted(reason:)` (iOS 15) · `.preferredColorScheme` (iOS 13) ·
`.formStyle(.grouped)` (iOS 16) · MusicKit `Artwork` colour properties (iOS 15)

> **Two of those contradict Apple's published documentation and are correct
> anyway. Do not "fix" them.** Both were read directly from
> `iPhoneOS26.5.sdk/…/SwiftUICore.swiftmodule/arm64e-apple-ios.swiftinterface`:
>
> - **`onGeometryChange` — line 6064** is `@available(iOS 16.0, macOS 13.0, …)`
>   and `@_alwaysEmitIntoClient` for the **single-value** overload
>   `(for:of:action:)` where `action` takes only `newValue`. The **two-value**
>   overload (`oldValue, newValue`) at **line 6075** is the iOS 18 one, and is
>   *not* `@_alwaysEmitIntoClient`. The docs describe the iOS 18 overload, which
>   is why everyone believes the whole API is iOS 18.
> - **The spring presets — line 13073** open with
>   `@available(iOS 13.0, macOS 10.15, …)`, and every member is
>   `@_alwaysEmitIntoClient` with a body bottoming out in the iOS 13
>   `spring(response:dampingFraction:)`.
>
> The tell in both cases is `@_alwaysEmitIntoClient`: the implementation is
> compiled into *this* binary rather than called out to the OS, so the annotation
> on the extension is the real floor. `@_originallyDefinedIn(module: "SwiftUI",
> iOS 26.0)` beside it just records that the symbol moved to `SwiftUICore`.
>
> **The build is the arbiter, not the docs.** If in doubt, write the call
> unfenced and run the iphonesimulator build — §7 shows it hard-errors.

**+iOS 18 / macOS 15 — fence required.**
`.matchedTransitionSource(id:in:)` · `.onScrollGeometryChange(for:of:action:)` ·
`.onScrollPhaseChange` · `ScrollGeometry` · `.toolbarBackgroundVisibility(_:for:)` ·
`.presentationSizing` · `.pointerStyle` (macOS 15)
⚠ `.navigationTransition(.zoom(sourceID:in:))` is iOS 18 **and
`@available(macOS, unavailable)`**.

**+iOS 26 / macOS 26 — fence required.**
`.glassEffect(_:in:)` · `Glass` · `GlassEffectContainer` · `.glassEffectID` ·
`.glassEffectUnion` · `.buttonStyle(.glass)` / `.glassProminent` ·
`.safeAreaBar(edge:...)` · `.scrollEdgeEffectStyle(_:for:)` ·
`.backgroundExtensionEffect()` · `ToolbarSpacer` · `ConcentricRectangle` ·
`.tabBarMinimizeBehavior` · `.tabViewBottomAccessory`

**Not reachable at all:** the `NowPlaying` framework (iOS 27) — there is no
`NowPlaying.framework` in `iPhoneOS26.5.sdk`, so it cannot be compiled against
even behind `#available`, because `#available` gates execution, not linkage.

### Writing a fence

Always name **both** platforms. `swift build` targets macOS, so an iOS-only
annotation compiles clean locally and fails on the simulator SDK — CLAUDE.md
already records this class of mistake costing a release-blocking bug.

```swift
if #available(iOS 26.0, macOS 26.0, *) { … }
```

The app has **zero** `#available` checks today, so the first one is a house-style
decision. Make it this: a fence lives in **one** `ViewModifier` or `@ViewBuilder`
`View` extension, never at thirty call sites. `glassEffect` and
`.background(_:in:)` return different types, and `PrimitiveButtonStyle.glass` and
`.bordered` are unrelated types, so the branch cannot be hoisted into a variable —
it has to be a modifier. Identity differing across the branch is harmless because
the OS version does not change at runtime.

---

## 2. The reading list

Only URLs that were fetched and returned real content. Apple's HIG HTML pages
return a JS shell to non-browser clients; **the JSON path that works omits the
`documentation/` segment**:
`https://developer.apple.com/tutorials/data/design/human-interface-guidelines/<page>.json`

### Read these five first, in this order

1. [Get to know the new design system — WWDC25 356](https://developer.apple.com/videos/play/wwdc2025/356/) — the vocabulary for everything the app is already rendering in.
2. [Animate with springs — WWDC23 10158](https://developer.apple.com/videos/play/wwdc2023/10158/) — why `duration`/`bounce` replaced `response`/`dampingFraction`, and what interruptible means.
3. [Beyond scroll views — WWDC23 10159](https://developer.apple.com/videos/play/wwdc2023/10159/) — the iOS 17 scroll suite, all of it at this project's floor.
4. [Designing Fluid Interfaces — WWDC18 803](https://developer.apple.com/videos/play/wwdc2018/803/) — still the best account of why gesture-driven UI must be interruptible. Directly describes what `PlayerExpansion` already does.
5. [Build a SwiftUI app with the new design — WWDC25 323](https://developer.apple.com/videos/play/wwdc2025/323/) — the adoption walkthrough.

### Human Interface Guidelines

| Page | What it settles |
| --- | --- |
| [Motion](https://developer.apple.com/tutorials/data/design/human-interface-guidelines/motion.json) | Reduce Motion is a cross-fade, not an absence |
| [Materials](https://developer.apple.com/tutorials/data/design/human-interface-guidelines/materials.json) | Glass is the control layer; content gets standard materials |
| [Color](https://developer.apple.com/tutorials/data/design/human-interface-guidelines/color.json) | Tint the *background* of a primary action, not its text |
| [Typography](https://developer.apple.com/tutorials/data/design/human-interface-guidelines/typography.json) | iOS default 17pt, minimum 11pt; avoid Ultralight/Thin/Light |
| [Layout](https://developer.apple.com/tutorials/data/design/human-interface-guidelines/layout.json) | Grouping and spacing; does *not* carry the tap-target number |
| [Accessibility](https://developer.apple.com/tutorials/data/design/human-interface-guidelines/accessibility.json) | Control sizes: iOS **minimum 28×28pt**, **default 44×44pt** |
| [Loading](https://developer.apple.com/tutorials/data/design/human-interface-guidelines/loading.json) | Placeholders immediately; spinners only past "a moment or two" |
| [Playing audio](https://developer.apple.com/tutorials/data/design/human-interface-guidelines/playing-audio.json) | Don't repurpose transport controls; pause on disconnect; permit rerouting |
| [Playing haptics](https://developer.apple.com/tutorials/data/design/human-interface-guidelines/playing-haptics.json) | Cause-and-effect only; synchronise intensity with the animation |
| [SF Symbols](https://developer.apple.com/tutorials/data/design/human-interface-guidelines/sf-symbols.json) | Rendering modes and the animation presets |
| [App icons](https://developer.apple.com/tutorials/data/design/human-interface-guidelines/app-icons.json) | Six appearance variants; let the system supply mask/glass/shadow |
| [Dark Mode](https://developer.apple.com/tutorials/data/design/human-interface-guidelines/dark-mode.json) | Permanent dark only for immersive media |
| [Toolbars](https://developer.apple.com/tutorials/data/design/human-interface-guidelines/toolbars.json) | Every toolbar item also a menu-bar command (macOS) |
| [Searching](https://developer.apple.com/tutorials/data/design/human-interface-guidelines/searching.json) | Placement conventions |
| [Lists and tables](https://developer.apple.com/tutorials/data/design/human-interface-guidelines/lists-and-tables.json) | |
| [Inclusion](https://developer.apple.com/tutorials/data/design/human-interface-guidelines/inclusion.json) · [VoiceOver](https://developer.apple.com/tutorials/data/design/human-interface-guidelines/voiceover.json) | |
| [UI Design Dos and Don'ts](https://developer.apple.com/design/tips/) | One-page sanity check |

### Liquid Glass / design system

- [Liquid Glass — Technology Overviews](https://developer.apple.com/documentation/TechnologyOverviews/liquid-glass)
- [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass) — the migration checklist
- [Applying Liquid Glass to custom views](https://developer.apple.com/tutorials/data/documentation/swiftui/applying-liquid-glass-to-custom-views.json)
- [Landmarks: Building an app with Liquid Glass](https://developer.apple.com/documentation/SwiftUI/Landmarks-Building-an-app-with-Liquid-Glass) — Apple's own sample
- [`UIDesignRequiresCompatibility`](https://developer.apple.com/tutorials/data/documentation/bundleresources/information-property-list/uidesignrequirescompatibility.json)
- [Meet Liquid Glass — WWDC25 219](https://developer.apple.com/videos/play/wwdc2025/219/)

### Motion and transitions

- [Explore SwiftUI animation — WWDC23 10156](https://developer.apple.com/videos/play/wwdc2023/10156/)
- [Enhance your UI animations and transitions — WWDC24 10145](https://developer.apple.com/videos/play/wwdc2024/10145/) — zoom transitions
- [Animate symbols in your app — WWDC23 10258](https://developer.apple.com/videos/play/wwdc2023/10258/)
- [What's new in SF Symbols 7 — WWDC25 337](https://developer.apple.com/videos/play/wwdc2025/337/)
- [`Animation`](https://developer.apple.com/tutorials/data/documentation/swiftui/animation.json) · [`navigationTransition(_:)`](https://developer.apple.com/documentation/swiftui/view/navigationtransition(_:)) · [`matchedTransitionSource(id:in:)`](https://developer.apple.com/tutorials/data/documentation/swiftui/view/matchedtransitionsource(id:in:).json)

### Identity

- [Say hello to the new look of app icons — WWDC25 220](https://developer.apple.com/videos/play/wwdc2025/220/) · [Create icons with Icon Composer — WWDC25 361](https://developer.apple.com/videos/play/wwdc2025/361/) · [Creating your app icon using Icon Composer](https://developer.apple.com/tutorials/data/documentation/xcode/creating-your-app-icon-using-icon-composer.json)
- [Communicate your brand identity on iOS — WWDC26 251](https://developer.apple.com/videos/play/wwdc2026/251/)
- [Apple Design Resources](https://developer.apple.com/design/resources/) · [SF Symbols](https://developer.apple.com/sf-symbols/)

### Kids and accessibility

- [Design safe and age-appropriate experiences](https://developer.apple.com/kids/) · [Parental gates](https://developer.apple.com/app-store/kids-apps/) · [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) (1.3, 5.1.4)
- [Deliver age-appropriate experiences — WWDC25 299](https://developer.apple.com/videos/play/wwdc2025/299/)
- [Catch up on accessibility in SwiftUI — WWDC24 10073](https://developer.apple.com/videos/play/wwdc2024/10073/) · [Refine accessibility for custom controls — WWDC26 220](https://developer.apple.com/videos/play/wwdc2026/220/)
- App Store Connect evaluation criteria — [Larger Text](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/larger-text-evaluation-criteria/) · [Sufficient Contrast](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/sufficient-contrast-evaluation-criteria/) · [Reduced Motion](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/reduced-motion-evaluation-criteria/) · [Differentiate Without Color](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/differentiate-without-color-alone-evaluation-criteria/)

### MusicKit

- [`Artwork`](https://developer.apple.com/tutorials/data/documentation/musickit/artwork.json) — the colour properties · [`ApplicationMusicPlayer`](https://developer.apple.com/tutorials/data/documentation/musickit/applicationmusicplayer.json)
- [Integrate MusicKit into your app — WWDC26 254](https://developer.apple.com/videos/play/wwdc2026/254/)

### Newer than this SDK — read, do not adopt

- [Meet the Now Playing framework — WWDC26 312](https://developer.apple.com/videos/play/wwdc2026/312/) — assessed and rejected, §6
- [What's new in SwiftUI — WWDC26 269](https://developer.apple.com/videos/play/wwdc2026/269/) · [What's new in Xcode 27 — WWDC26 258](https://developer.apple.com/videos/play/wwdc2026/258/) — describe APIs not in SDK 26.5

---

## 3. The rules

### 3.1 Motion

**Springs are not a preference; they are already SwiftUI's default.** From
WWDC23 10158: *"Because springs are such a great tool for animations, we now use
them as the default animation in SwiftUI, so all you need to do is call
`withAnimation`."* Every `.easeInOut(duration:)` in this codebase is an active
decision to override that default with something worse.

**"Interruptible" has a precise mechanism.** From WWDC23 10156: *"Spring
animations override `shouldMerge` to return true and incorporate the state of the
previous animation. This allows them to preserve velocity and retarget to the new
value. The default implementation returns false — this is what timing curve
animations do — in which case both animations will be run together, and their
results will be combined by the system."*

That is the whole argument. Tap play twice in 200ms and an eased animation runs
two curves additively; a spring picks up the in-flight velocity and retargets.
Kids tap things twice. For anything a finger drags, easing is not merely worse
but incapable — 10158 again: *"its motion jerks to a halt as the gesture ends.
This type of animation is just a prespecified curve, so there's no way to
represent an initial velocity."*

**Easing is still correct in exactly two places:** a pure opacity cross-fade with
no spatial component (nothing bounces along an alpha channel), and the Reduce
Motion substitute.

**Availability — settled by reading the SDK.** `SwiftUICore.swiftinterface:13073`
opens the extension with `@available(iOS 13.0, macOS 10.15, ...)` and every
preset inside is `@_alwaysEmitIntoClient` with a body bottoming out in the iOS 13
`spring(response:dampingFraction:)`. So `.smooth` / `.snappy` / `.bouncy` /
`.spring(duration:bounce:)` / `.interactiveSpring(duration:)` are genuinely
back-deployed — **no fence, anywhere.** Bounce values confirmed from source:
smooth `0.0`, snappy `0.15`, bouncy `0.3`.

One distinction worth keeping straight: the `Animation` *presets* are iOS 13; the
`Spring` *value type* (`:3091`) and `Animation.spring(_: Spring, blendDuration:)`
(`:3207`) are iOS 17 / macOS 14. Both clear the floor unconditionally.

#### The table

| Interaction | Value | Why |
| --- | --- | --- |
| Nav push/pop | *system default — do not override* | `NavigationStack` already springs; a custom curve desynchronises from the gesture-driven back-swipe. |
| Branch swap home/searching/results/trouble (`KidHomeView.swift:127`) | `.easeOut(duration: 0.18)` + `.transition(.opacity)` | The one correct easing: nothing travels, so there is no velocity to preserve. Today's `0.2` easeInOut is right by accident — make it deliberate and shorten the tail. |
| Player open/close settle (`PlayerExpansion.swift:49`) | `.snappy(duration: 0.42, extraBounce: -0.03)` | Identical to today's `bounce: 0.12`, but named. A screen-sized surface needs longer than a tile. |
| **Drag release — flick *and* haul** | the *same* `settle`; velocity arrives from the gesture | SwiftUI "will now automatically track velocities any time a gesture is changing properties" (10158). Two constants here would double-count what the gesture already supplies. |
| Drag cancel / snap-back | `settle` | `release(projected:)` already distinguishes intent by threshold; motion should not re-litigate it. |
| Scroll-to-top (`KidHomeView.swift:506`) | `.snappy(duration: 0.45, extraBounce: -0.15)` → bounce 0 | Long spatial travel. Bounce past a scroll boundary reads as a rubber-band that never happened. Never `.bouncy`. |
| Play/pause glyph | `.snappy(duration: 0.3)` driving `.contentTransition` | See below — the animation is mandatory, not optional. |
| Heart filling | `.bouncy(duration: 0.4, extraBounce: 0.05)` | The one place overshoot *is* the content — a kid's reward, and the only tap that means *mine*. |
| Artwork over placeholder | `.easeOut(duration: 0.25)`, opacity only | Nothing moves; the image resolves. Scaling artwork in draws the eye to a loading state. Suppress entirely on an `ArtworkCache` memory hit. |
| Shelf reloading under the kid | `.smooth(duration: 0.5)` → bounce 0 | The kid did not ask for this. Bounce claims credit for a change nobody initiated. |
| Skeleton pulse (`KidHomeView.swift:1026`) | `.easeInOut(0.9).repeatForever`, **`nil` under Reduce Motion** | Keep the curve — a two-state opacity loop is the one legitimate `repeatForever`. Guard it. |
| Press-down on a tile | `.interactiveSpring(duration: 0.2)` on scale 0.96 | Highest blend, shortest duration — the finger is still down and must be able to change its mind mid-press. |
| Admin list insert/delete | `.snappy(duration: 0.3)` + `.animation(_:value:)` | Currently a hard cut. A parent deleting a deny needs to see *which* row left. |

#### How it lives in code

An `enum` alone cannot do this — Reduce Motion is an environment value and a
`static let` cannot read the environment. **Use both:** an `enum` for the
vocabulary, an `EnvironmentKey` for the single place substitution happens.

```swift
enum Motion {
    static let interactive = Animation.interactiveSpring(duration: 0.2)
    static let standard    = Animation.snappy(duration: 0.3)
    static let settle      = Animation.snappy(duration: 0.42, extraBounce: -0.03)
    static let travel      = Animation.snappy(duration: 0.45, extraBounce: -0.15)
    static let playful     = Animation.bouncy(duration: 0.4, extraBounce: 0.05)
    static let fade        = Animation.easeOut(duration: 0.18)
    static let ambient     = Animation.smooth(duration: 0.5)
    static let pulse       = Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)
    /// Apple's substitute is a cross-fade, not an absence.
    static let reduced     = Animation.easeInOut(duration: 0.2)
}
```

Wrap those in a `MotionPalette` struct that resolves each through
`reduceMotion ? Motion.reduced : raw`, put it in the environment under
`\.motion`, and apply one `.resolvingMotion()` modifier on `RootView`. Call sites
read `@Environment(\.motion)` and are then correct by construction.

`pulse` is the one member that returns `Animation?` and yields **`nil`** under
Reduce Motion — a `repeatForever` attached to a value that never changes again
runs forever no matter how gentle the curve. `SearchingView.swift:60-70` already
does exactly this and says so in its comment; `HomeSkeleton`
(`KidHomeView.swift:1026`) has the identical loop and is **not** guarded. One
file solved it and the other did not, which is the strongest argument here for a
shared vocabulary.

HIG Accessibility asks for *"replacing transitions in x-, y-, and z-axes with
fades to avoid motion"* and *"tightening animation springs to reduce bounce."*
That is a cross-fade, not `nil` — which is why only `pulse` returns `nil`.

**One friction point, stated honestly:** `PlayerExpansion` is a model, not a view,
so it cannot read the environment. `open()`, `close()` and `release(projected:)`
must take the palette as a parameter from the view owning the gesture. That is the
right shape anyway — it makes the dependency visible.

#### The play/pause glyph — settled

`.contentTransition(.symbolEffect(.replace))` alone **silently does nothing.**
`SwiftUICore.swiftinterface:15815` shows the modifier's entire body is
`environment(\.contentTransition, transition)`. It describes *how* to interpolate
if there is an animation in the transaction; with none, a flip of
`player.isPlaying` is a plain rebuild, and a rebuild is a cut.

And there is no escape route, because `Symbols.swiftinterface` shows
`ReplaceSymbolEffect` conforms to `SymbolEffect` and
`ContentTransitionSymbolEffect` **only** — it is absent from the
`DiscreteSymbolEffect`, `IndefiniteSymbolEffect` and `TransitionSymbolEffect`
conformer lists. So `.symbolEffect(.replace, value:)`,
`.symbolEffect(.replace, isActive:)` and `.transition(.symbolEffect(.replace))`
**do not compile.** `.contentTransition` is `.replace`'s only route, and it is the
one that needs a driver.

```swift
Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
    .font(.title)
    .contentTransition(.symbolEffect(.replace))
    .animation(motion.standard, value: player.isPlaying)   // ← remove this and it cuts
```

Both modifiers go on the `Image`, not the `Button` — otherwise the label's rebuild
happens outside the animated scope — and `.animation` must come below
`.contentTransition` in source. `.animation(_:value:)` writes into the transaction
only when the value actually changed, so a rebuild for any other reason correctly
stays a cut.

`.symbolEffect(_:value:)` is the *self-driving* alternative and needs no
transaction animation, but it is unavailable for `.replace`. Use it for the
heart — `.symbolEffect(.bounce, value: isOn)` compiles, because
`BounceSymbolEffect: DiscreteSymbolEffect`.

⚠ `.replace.magicReplace` is iOS 18 / macOS 15 — fence it or skip it.

### 3.2 Materials and the design system

**Glass is the control layer. Materials are the content layer.** HIG Materials
says it directly: don't use Liquid Glass in the content layer, and use it
sparingly, for the most important functional elements. A kid player whose tiles
are all glass makes the controls indistinguishable from the artwork behind them.

**The floor fallback for glass is `.background(.regularMaterial, in: shape)`** —
a sanctioned degrade, not an approximation, because Apple positions standard
materials as glass's content-layer counterpart. `.buttonStyle(.glass)` falls back
to `.bordered`; `.glassProminent` to `.borderedProminent`.

**Hierarchical styles preserve vibrancy over a material; a custom
`foregroundStyle` kills it** for that subtree. The codebase depends on this 82
times. Keep `.secondary` / `.tertiary` / `.quaternary`; never substitute a literal
grey.

**Honour `accessibilityReduceTransparency`.** It is the one accessibility signal
that a custom view must handle by hand — swap the material for an opaque semantic
colour.

**`Material.bar` is the *old* toolbar frosting** and does not become glass on iOS
26. Where a bar is being redesigned anyway, gate it (§5.1). Where it is not —
`SearchView.swift:40`, `PlayerBar.swift:32`, both on the adult Diagnostics
screen — leave it; a flush `.bar` is right there.

**Never composite on artwork.** Clip it, shadow it, put a gradient *behind* it.
Nothing is ever drawn on top. This is a licence position (ADP §3.3.6(D)), not a
taste one, and it is why the heart lives in the row below the cover.

### 3.3 Colour and identity

The app has no colour. `Assets.xcassets` contains only `AppIcon.appiconset`.

**Ship three colour sets, not one.** The split is forced by arithmetic, not
taste: a colour that reads *as* text on a dark background needs relative
luminance ≥ 0.276; a colour that carries a white label *behind* it needs ≤ 0.183.
No single value satisfies both, so one `AccentColor` used for both roles silently
fails contrast in dark mode.

| Set | Role | Call sites |
| --- | --- | --- |
| `KidAccent` | foreground tint | the `.tint` / `.foregroundStyle(.tint)` sites |
| `KidAccentFill` | background of primary actions | `.borderedProminent` at `AlbumView.swift:63`, `ArtistView.swift:102`, `KidHomeView.swift:478` |
| `AdminAccent` | the grown-up half | `.tint(.adminAccent)` on the admin sheet, `KidHomeView.swift:223` |

Each colour set needs four entries: base, `luminosity: dark`, `contrast: high`,
and both. Set
`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = KidAccent` in **both** build
configurations (beside `ASSETCATALOG_COMPILER_APPICON_NAME`). Do not create a set
literally named `AccentColor` — the setting takes a name.
`ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_FRAMEWORKS = SwiftUI` is already set,
so `Color.kidAccent` appears with no string literal.

Per CLAUDE.md's warning about silently-ignored build settings: verify with
`plutil -p` on the built app, look for `NSAccentColorName`, and never use
`plutil -extract` without `-o -`.

**Splitting kid and parent accents is deliberate.** The passcode gate is a mode
boundary and a parent should see at a glance which half they are in; the admin
sheet is a clean scope with no leakage; and the *kid* accent is the one the
system shows on the Home Screen and in macOS controls, which should be the
child's colour because the child is the one holding the device.

**macOS caveat:** if the user picks a non-multicolour system accent, the system
applies *their* colour throughout the app. An explicit `.tint(_:)` still wins;
the global accent does not.

### 3.4 Typography

**`.fontDesign(.rounded)` is the one-line lever for the kid half** — iOS 16.1 /
macOS 13.0, below the floor, applies to a whole subtree. It belongs at the
**outermost** point of `KidHomeView.body` — *after* the `.sheet` at line 223, not
on the `NavigationStack` at 122. Environment flows outside-in, so an inner
placement misses the `.safeAreaInset` bars (209) and the `ExpandedPlayer` overlay
(216), which are the two most kid-facing surfaces in the app. Reset with
`.fontDesign(nil)` on the sheet's inner `NavigationStack` so the grown-up half
stays SF Pro. Leave `RootView` alone — it is parent-facing.

**The four `.font(.system(size:))` sites are two different problems.**

- `AlbumView.swift:102` (48) and `ArtistView.swift:78` (56) are *decorative*
  placeholder glyphs, `accessibilityHidden(true)`, sized to a fixed box. They are
  **correct to stay fixed** — derive them from the frame constant and add a
  comment saying why.
- `NowPlayingView.swift:322` (44) and `:333` (30) are **controls**. They should
  become `@ScaledMetric(relativeTo: .largeTitle)` with their 88/60 hit frames
  scaled by the same ratio and capped.

A pleasant accident worth knowing: `.font(.system(size:))` resolves to the iOS
16+ overload whose `design` parameter defaults to `nil`, not `.default`, so these
four sites will *inherit* `.rounded` rather than opting out of it. They still opt
out of Dynamic Type, which is the actual defect.

**Fixed heights and Dynamic Type — observed on a running build at AX5, not
predicted.** `KidHomeView.swift:1095` `.frame(height: tileWidth + 84)` and
`KidSearchBar.swift:37` `height: 52`.

The failure is worse than "the frame clips." Because the shelf height is fixed
and `Tile`'s artwork is `.aspectRatio(1, contentMode: .fit)` *inside* it, growing
text does not overflow the tile — **it evicts the artwork.** At
`accessibility-extra-extra-extra-large` the album covers shrink to roughly a
quarter of their normal size, sitting as postage stamps above two lines of
truncated title ("Tig r…", "In a…"). A shelf of tiles is the one surface in this
app that a pre-literate child navigates *entirely by picture*, so the accessibility
size that exists for people who cannot read small text is the exact size at which
this app removes the pictures and leaves the words.

The heart glyph also scales while its reserved 28pt gutter does not, so it
overflows its column; the now-playing bar's title becomes "Al…" / "Mi…"; and the
bottom chrome grows to roughly 30% of the screen.

Fix: `@ScaledMetric(relativeTo: .headline)` on `tileWidth`, derive the height from
the same metric rather than the literal `84`, and cap growth — or drop the outer
`.frame(height:)` entirely and let the `HStack` size itself. Either way the
artwork must have a floor it cannot be squeezed below.

### 3.5 Colour scheme

**Do not force dark mode.** Apple Music itself does not — its album and Now
Playing surfaces are artwork-adaptive. HIG permits a permanent dark appearance
only "for an app that supports immersive media viewing."

There is a specific architectural trap here: `ExpandedPlayer` is an
**always-present overlay**, so `.preferredColorScheme(.dark)` on it forces the
*whole window* dark permanently — `preferredColorScheme` propagates to the
enclosing presentation, not the subtree. If the player is ever committed to a
dark appearance, use `.environment(\.colorScheme, .dark)`.

### 3.6 Layout and components

- **Continuous corners.** `RoundedRectangle(cornerRadius:)` defaults to
  `.continuous` in SDK 26.5 — verified in `SwiftUICore.swiftinterface`. Passing
  `style: .continuous` explicitly is still worth it as documentation.
- **The scattered radii (8 / 12 / 16) want to be named.** So do the two
  near-identical metrics enums, `SongRowMetrics` (`KidHomeView.swift:1226`) and
  `AlbumTrackMetrics` (`AlbumView.swift:299`), and the tile width `150` that
  appears in four places.
- **Shelves should snap.** `.scrollTargetLayout()` on the `HStack` +
  `.scrollTargetBehavior(.viewAligned)` on the `ScrollView`, and
  `.contentMargins(.horizontal, 16, for: .scrollContent)` instead of
  `.padding(.horizontal)` *inside* the content — the inner padding is why the
  first and last tiles sit oddly against the edges. All floor, no fence.
- **Empty and loading states.** `ContentUnavailableView` (iOS 17) for the empty
  case; a skeleton, not a bare `ProgressView`, wherever a cold fetch is on screen
  for more than a moment. `HomeSkeleton` already exists and already argues this
  well in its own doc comment — the four detail screens
  (`AlbumView.swift:55`, `ArtistView.swift:93`, `PlaylistView.swift:34`,
  `LibraryView.swift:74`) each still show a bare spinner.
- **Press feedback.** `.buttonStyle(.plain)` gives *no* pressed state. Every kid
  tap target should use one shared `ButtonStyle` reading
  `configuration.isPressed`.
- **Icon-only buttons need labels.** `Button("Grown-ups", systemImage: "lock.fill")`
  with `.labelStyle(.iconOnly)` (iOS 17) keeps the label and glyph from drifting
  apart. Same for the `ellipsis.circle` menu at `PlaylistView.swift:81` — use
  `Label("More", systemImage: "ellipsis")` and let the system draw the toolbar
  button's own circular background rather than stacking a drawn ring inside it.

### 3.7 Hit targets

HIG Accessibility gives, for iOS/iPadOS: **minimum 28×28pt, default 44×44pt.**

`HeartButton.size = 28` (`LibraryControls.swift:24`), reused at six call sites,
is therefore *exactly on the minimum with zero margin*. It is not a violation.
It is also not right for a six-year-old — the argument for 44 here is the child's
finger, not the HIG number. Grow the target without growing the glyph:
`.frame(width: 44, height: 44)` + `.contentShape(.rect)`, or
`.contentShape(Rectangle().inset(by: -8))`.

The bar's play/pause and skip buttons (`NowPlayingBar.swift:119-134`) have **no
frame at all** — the target is the glyph's own bounds, ~24–28pt. That one is a
plain defect; `NowPlayingView.swift:323` already does it correctly.

### 3.8 What the child actually reads

**Found by running the app on 2026-08-03. This is a real defect, not a
refinement.** The kid's player displayed, in the message slot under the scrubber:

> The operation couldn't be completed. (MPMusicPlayerControllerErrorDomain error 6.)

`NowPlayingBar.swift:46-48` and `NowPlayingView.swift:124-125` both describe that
slot as *"The only block a kid is ever shown... Plain words, no error code, and no
mention of the rule."* The invariant is right; the implementation does not hold it.

`Session.swift:2021` is the leak:

```swift
static func message(for error: any Error) -> String {
    (error as? CatalogError)?.errorDescription ?? error.localizedDescription
}
```

Anything that is not a `CatalogError` reaches the child verbatim — domain, code and
all. `KidPlayerModel` uses it at `:243` and `:542`. Line `:527` shows what the
right answer looks like and is the only one written for the reader:
`"Skipping this one — let's try the next."`

**Rule: no string originating from a framework is ever rendered on a kid surface.**
`message(for:)` should map to a small, closed set of hand-written sentences and
fall back to a generic kid-safe one, with the underlying error logged rather than
displayed. Framework text is fine on the parent side, where it is diagnostic.

This is a styling concern in the only sense that matters here: it is what a
six-year-old who cannot read sees on the largest screen in the app.

### 3.9 macOS

The Mac is the half that will look worst, and it has the *wider* gap: floor
macOS 14, glass at macOS 26.

**Three defects that precede any design question:**

1. **`WindowGroup` gives File ▸ New Window / ⌘N.** `Session` is app-level `@State`
   and shared, but `KidPlayerModel` is built in `KidHomeView.init`, so a second
   window builds a **second player model over the one `ApplicationMusicPlayer`** —
   two queues, each inserting under the two-entry rule without knowing about the
   other. Use `Window(_:id:)` plus `CommandGroup(replacing: .newItem) {}`.
2. **`.navigationTitle("")` at `KidHomeView.swift:152` is not fenced.** On macOS
   `navigationTitle` is the *window* title — title bar, Window menu, Mission
   Control, ⌘-Tab. The kid's Mac window is literally unnamed. The iOS reason (a
   large-title band that scrolls, and `scrollTo` landing below it) has no macOS
   analogue.
3. **A 380×620 sheet on a 520×720 window** is a modal takeover that also covers
   the toolbar, so the parent cannot reach the lock while the player is up.

**Keep the single `NavigationStack` for the kid.** A sidebar is persistent on
every screen including inside an album — exactly the escape hatch the product
forbids — and it introduces a second navigation authority `KidRouter.collapsed(_:)`
cannot see, which is the whole reason the path is `[KidRoute]` and not a
`NavigationPath`. Removing the toolbar toggle does **not** remove View ▸ Show
Sidebar / ⌃⌘S from the menu bar; the hatch survives the toolbar edit.

**The admin is the opposite.** It is a nine-section `Form` in a sheet where every
list is a `NavigationLink` push — an iPhone pattern on a desktop. HIG macOS:
"Leverage large displays to present more content in fewer nested levels and with
less need for modality." Move it to a `NavigationSplitView` in its **own**
`Window(id: "admin")`, opened with `openWindow` after `AdminGateView` passes.

**Window:** `.windowResizability(.contentMinSize)` + a `minWidth`/`minHeight` on
the root. Not fixed-size — HIG asks that people be able to resize, hide, move and
full-screen windows.

⚠ **`.containerBackground` is a trap.** The method is macOS 14, but `.navigation`
and `.navigationSplitView` are `@available(macOS, unavailable)` and the only
macOS placement, `.window`, is **macOS 15**.

**Pointer and keyboard**, all absent today: `.onHover` is macOS 10.15;
`.hoverEffect` is `@available(macOS, unavailable)`; `.pointerStyle` is macOS 15.
Space (withdrawn while typing) for play/pause and ⌘→ for next, via `CommandMenu`
+ `@FocusedValue`. HIG Toolbars: make every toolbar item available as a menu-bar
command.

---

## 4. The set-pieces

These four are the things the request specifically described. Each has a verified
recipe; the two hardest were adversarially reviewed and both came back
SOUND-WITH-FIXES, with the fixes folded in below.

### 4.1 The floating capsule mini-player · **Gated**

**The disqualifying fact first:** `.tabViewBottomAccessory` — the one first-party
API that produces this look — is a modifier *on a `TabView`*, is
`@available(iOS 26.0, *)` with macOS/tvOS/watchOS/visionOS **unavailable**, and
this app has **zero** `TabView`s. It compiles on any view and silently does
nothing outside a `TabView`, and it hard-errors the macOS build. Adding a
`TabView` to reach it would hand the kid a second navigation model. Not an option.

**Anatomy.** Apple publishes no point values for the Music mini player; the
structure below is confirmed from HIG, the numbers are chosen to match system
conventions and the app's existing rhythm.

| | iOS | macOS |
| --- | --- | --- |
| Side inset | 16 | 16, stack capped at 720 centred |
| Gap above safe area | 8 | 14 |
| Gap between the two capsules | 8 | 8 |
| Now-playing row height | ~60 (artwork 44 + 8/8) | same |
| Search row height | 52 | same |
| Inner padding | 10 h / 8 v | same |
| Artwork | 44, 8pt continuous radius, `@ScaledMetric(relativeTo: .headline)` capped at 64 | same |

Total reserved ≈ **128pt**, *less* than today's ~156.

**The two-row treatment survives — as two separate floating capsules**, plus a
third shape: the home button becomes its own glass circle beside the search
capsule. One tall capsule containing both rows is wrong twice — it is a slab, and
the search field is *already* `Capsule()`-shaped (`KidSearchBar.swift:95`), so it
would be glass inside glass. Nothing is removed; home and search both stay.

**Use `RoundedRectangle(cornerRadius: 28, style: .continuous)` — not `Capsule`,
and not a switch between them.** The row is not height-stable: `player.message`
adds a second line and Dynamic Type grows it, so a true capsule becomes a lozenge
at 100pt. An `AnyShape` switch between `Capsule` and `RoundedRectangle` is worse
than either: SwiftUI cannot interpolate two `AnyShape` values, so the radius
**jumps** at the moment the message appears — a glitch on the one occasion the app
is showing a child a block message. At the 60pt design height, r=28 against a
capsule's r=30 is indistinguishable. This also keeps the shape `InsettableShape`,
which the stroke needs (below), and deletes `AnyShape` entirely.

**The `.background(.bar)` situation — corrected by observation, 2026-08-03.**

An earlier draft of this file called the two `.background(.bar)` applications
(`NowPlayingBar.swift:138`, `KidSearchBar.swift:58`) a *double-darkening
compositing defect*. **That was wrong.** The two bars are **adjacent siblings** in
the `bottomBars` `VStack` (`KidHomeView.swift:327-331`), not stacked views — each
material covers its own band and nothing composites through anything else.
Sampling a vertical strip down the left edge of a running build gives
`(246,249,250)` in the now-playing band and `(246,248,246)` in the search band:
no doubling.

What is *actually* there is a **visible tonal seam** at the boundary between the
two bands, because each material resolves against whatever content sits behind
its own band. It is subtle in light mode and clearly visible in dark. That is a
cosmetic argument for the single floating treatment, not a correctness one — so
this section's recommendation stands, but on aesthetic grounds alone. Do not
repeat the compositing claim.

The fix remains **one surface per floating shape, and the shapes must never
overlap**: delete `.background(.bar)` from both, give each capsule exactly one
surface, and let the 8pt gap separate them.

**Use `strokeBorder`, not `stroke`.** `stroke` centres the 0.5pt hairline *on*
the path, so half of it lands outside the material as a fringe over the content
behind — worst along the caps.

**On the pre-26 path, do not put `.shadow` after `.compositingGroup()`.** That
paints the drop shadow *behind a translucent fill*, so it shows through the
capsule as a grey halo inside its own edge — the same defect class as two stacked
`.bar`s, moved somewhere new, on the path that covers iOS 17/18/25. Use the
shape-style form instead:

```swift
.background {
    shape.fill(.regularMaterial.shadow(.drop(color: .black.opacity(0.14), radius: 10, y: 3)))
}
.overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
```

and drop `compositingGroup()` — especially off the search field, which holds a
live focused `TextField` and would otherwise composite offscreen on every
keystroke.

**Clip the outer container, don't just set `contentShape`.** A parent's
`contentShape` does not clip a descendant's hit region.
`NowPlayingBar.swift:101` keeps `.contentShape(Rectangle())` + `.onTapGesture` on
the inner `HStack`, so once the bar floats, the transparent corners of the capsule
still open the full-screen player — a kid aiming at a tile visible *through* the
corner gets the player. Apply `.clipShape(barShape)` to the outer `VStack`.

**The critical placement finding.** The bars are drawn by `.safeAreaInset`
*outside* the `NavigationStack` (`KidHomeView.swift:209`), which — as the comment
at line 773 already records — insets nothing inside the stack. **Swapping that
call to `safeAreaBar` buys nothing**, because it cannot reach the ScrollViews.
The edge effect has to come from the per-screen reservation instead: change
`reservingBottomBars(_:)` at `KidHomeView.swift:803`. That keeps the single-draw
invariant intact and puts the blur where the capsules actually float.

`safeAreaBar` earns its fence for exactly one reason, in Apple's words: it is
like `safeAreaInset` and "**additionally, it extends the edge effect of any scroll
views affected by the inset safe area**."

**Do not hide Skip at accessibility sizes.** A kid at AX3+ is precisely the kid
who cannot read the title and navigates by pressing glyphs, and skip-stopping-at-
the-end-of-queue is this app's substitute for the autoplay it refuses. If room is
needed, drop the heart (favouriting is not time-critical) or let the row wrap — at
AX sizes the shape is a rounded rectangle already, so vertical growth is free.

**Watch on device:** `safeAreaBar` ties the edge-effect region to the *whole*
inset, which here is two capsules plus two gaps ≈ 128pt. `.soft` will fade across
that entire band where Apple's own are roughly one bar tall. If it reads as a
smear, the problem is not the style — it is that the reservation and the effect
region want to be two numbers and `safeAreaBar` makes them one.

### 4.2 The morph to full screen · **Floor**

The 56pt bar thumbnail travelling and growing into the ~420pt hero. This is the
part of the request with no system API behind it, and the reason is worth stating
once: **every system morph is a state-transition API with no progress input, and
`PlayerExpansion` is a continuously reversible gesture.**

| Option | Verdict |
| --- | --- |
| `matchedGeometryEffect` with `isSource` flipped on `isOpen` | **Unusable.** Nothing flips mid-drag, so the cover stays pinned at the bar rect for the whole travel and then animates the entire journey at release over a fixed 0.35s while the player only has whatever travel the finger left. It cannot express "half open". |
| `.matchedTransitionSource` + `.navigationTransition(.zoom)` | **Good API, wrong trade.** iOS 18 **and `@available(macOS, unavailable)`**. Requires a *presentation*, so adopting it deletes the overlay — and with it the reversible half-open state, the "never inserted, never removed" property that fixed the mid-slide flashes, macOS parity, and iOS 17. Two motion designs to maintain forever, to buy a transition on one platform above the floor. |
| `glassEffectID` / `GlassEffectContainer` | **Not applicable.** iOS 26 only, and it morphs glass *material shapes* merging and splitting. It cannot move a bitmap, and using it here would mean compositing glass onto artwork. |
| **Hand-rolled, driven by one scalar** | **This one.** |

**The recipe.** Derive `progress = 1 - offset/screenHeight` (clamped) on
`PlayerExpansion`, and put it behind an **`Animatable` conformance** so SwiftUI
interpolates it frame-by-frame during the settle spring exactly as it interpolates
`.offset`'s animatable data. That is the piece that makes it not a hack: the drag
path and the animation path become literally the same code, so they cannot drift.
Because `offset` and `progress` are affine, one spring on `offset` is the same
normalised curve on `progress` — same duration, same bounce, same interruption
velocity.

Measure both endpoints with `onGeometryChange(for:of:action:)` — the **single-value
overload is iOS 16 / macOS 13**, below the floor, no fence, no `PreferenceKey`.
(The two-value overload is the iOS 18 one.) Draw one flying copy positioned by
`lerp(barRect, heroRect, p)`, with the corner radius lerped 8→16 and the shadow
ramped 0→12. Both endpoints are always laid out, because `ExpandedPlayer` is never
removed from the hierarchy — which is what makes this cheap here and expensive
anywhere else.

**Swift 6 requires `nonisolated var animatableData`.** Without it:
*"conformance of 'MorphingArtwork' to protocol 'Animatable' crosses into main
actor-isolated code"*. Confirmed by compiling at
`-target arm64-apple-ios17.0-simulator -swift-version 6`.

**Four fixes the adversarial review found, all required:**

1. **Remap the cover's parameter off the measured rects, not raw `p`.** The
   player's opaque background does not reach the bar's cover until `p ≈ 0.19`, so
   from `p ≈ 0.05` a growing album cover flies *naked over the home screen* with a
   hole where the bar's cover was. On a tap that is 50ms; on a **drag held
   half-open** — the entire justification for `PlayerExpansion` existing — it is a
   stable state a kid is staring at. Use
   `q = clamp((p - pClear)/(1 - pClear))`, `pClear = 1 - (barRect.maxY + 16)/screenHeight`.
   Still a pure function of the interpolated `p`, so the no-drift property
   survives; the cover simply emerges from behind the player's leading edge, which
   is what Apple Music does.
2. **Do not assume two overlays resolve to the same origin.** Record the player's
   own pre-offset origin in `.global` and convert explicitly. If they differ the
   cover lands high by the top inset (~59pt) — "almost right", which is the worst
   failure mode for something that cannot be seen from this machine.
3. **Do not clamp the rect interpolation in `body`.** The settle spring
   overshoots; `.offset` interpolates past its endpoint and so should `progress`.
   Clamp the corner-radius and shadow ramps, not the rect — the clamp is what
   breaks the affine guarantee at the one moment the spring is nonlinear.
4. **Honour Reduce Motion.** A cover that translates and triples in size is the
   archetypal case, and this is a children's app. Hold `p` at `isOpen ? 1 : 0` and
   hide the flying copy. ~4 lines, not optional.

**Do not add a label cross-fade.** `NowPlayingView.swift:141-156` records that
gating work on `isShowing` cost two bug reports precisely because "the screen is
already in its final form before it starts travelling." A fade that brings content
in over `p ∈ [0.15, 0.6]` deliberately reintroduces content that is not in its
final form while the screen moves, and on a slow drag parks a full-screen opaque
background with a cover and no words on it.

**The "cheaper 80%" premise is backwards in this app.** The bar sits ~130pt above
the bottom, so the sliding player occludes it once `p > ~0.19` — the bar's labels
are invisible for over 80% of the travel and have almost no screen time to
cross-fade in. The album cover is the *only* object shared between the two states
and the only thing the eye tracks. **The artwork morph is the 80%.**

Cost: ~150 new lines, four small call-site edits, one new `@Observable`. No
dependency, nothing leaves the device, no policy surface touched, no artwork
written or composited.

**First thing to tap on device:** the album link on the hero cover. `cover(for:)`
hangs its tap, its accessibility and its denied-album guard on the view that
becomes an opacity-0 slot. SwiftUI *does* keep `.opacity(0)` hit-testable (unlike
UIKit `alpha`), so this is very likely fine — but the failure mode is exactly the
"dead picture" that `NowPlayingView.swift:169-174` exists to prevent.

### 4.3 The auto-hiding header · **Floor**

"Auto-hiding header" is three different things, and the prior confusion came from
treating them as one.

1. **Title hand-off** — the name moves from the content into the bar as you
   scroll, and the bar background fades in with it. Apple Music's album page.
   **This is what Album and Artist want.**
2. **Large-title collapse** — the system's *free* version of (1), where the title
   also owns a tall band at rest. `.navigationBarTitleDisplayMode(.inline)`
   switches it off.
3. **Chrome that retracts on scroll-down and returns on scroll-up** — Safari's
   bars. There is genuinely no API. **Do not build it here.**

**Per screen:**

- **`AlbumView.swift:47` — keep `.inline`.** The comment is right that a large
  title would print the album's name twice, ~44pt apart. But it justifies only
  half of what the line does: `.inline` also leaves the bar *permanently empty and
  permanently transparent*, so once the kid scrolls past the cover the screen has
  no name anywhere. **That** is the defect. The fix is not deleting line 47 — it
  is adding the hand-off, so the bar picks the name up exactly as the content
  drops it.
- **`ArtistView.swift:41`** — identical, same fix.
- **`KidHomeView.swift:153` — keep `.inline`, add no hand-off.** Both stated
  reasons hold and one is load-bearing: `proxy.scrollTo(Self.homeTop, anchor: .top)`
  at line 507 anchors *below* the large-title area, so restoring a large title
  re-breaks a fixed bug.
- **The bottom bars — never retract them.** It would animate `barHeight`, which
  every screen reserves through `reservingBottomBars`, reflowing the whole stack
  per frame. It also hides the transport controls from a six-year-old, failing
  HIG's "offer ways to reliably restore hidden interface elements."

**Implement the hand-off by measuring the title, not a scroll offset.** The point
at which the bar takes the name over is the point the content stopped saying it —
however tall the cover in front of it turned out to be. A `contentOffset`
threshold needs the bar's own inset taken back out and differs per device; the
title's own bottom edge is the same number everywhere. Use the
`GeometryReader`-in-`.background` + `PreferenceKey` + `.named` coordinate space
pattern the house already speaks twice (`KidHomeView.swift:332-337`,
`AlbumView.swift:155-163`). Reserve `onScrollGeometryChange` (iOS 18) for phase
and velocity, which that pattern genuinely cannot give.

**Skip the stretchy overscroll header.** Apple does not do it — Music's album
cover scrolls flat — and it reads as 2016 Spotify. Here it would also scale
artwork drawn at `maxWidth: 280` from a 512px source, so a 2× stretch samples
above the source and softens exactly when it is largest.

**Availability note:** `.toolbarBackground(_:for:)` is iOS 16 and usable now
(soft-deprecated, no warning today). `.toolbarBackgroundVisibility(_:for:)` is
**iOS 18**, so it cannot replace it at the floor.

### 4.4 Artwork resolution · **Floor**

`MusicKitCatalogSource.swift:27` and `:419` default to `artworkSize: Int = 512`,
and `NowPlayingView.swift:211` draws the hero at `.frame(maxWidth: 420)` inside
`.padding(.horizontal, 32)`.

**Measured on a running build (iPhone 17 Pro, 2026-08-03), not calculated:** the
hero renders **1077px wide — about 359pt — from a 512px source, a 2.1× upscale.**
On a wider phone it hits the 420pt cap and reaches 2.46×. Magnifying the fine
credits text on *Kind of Blue* shows smooth interpolation gradients where a native
render would give crisp pixel edges: it is visibly, confirmably soft.

**Both ends are wrong**: the hero upscales ~2×, and the 56pt row thumbnail
downloads and decodes that same 512px bitmap (~1MB resident) to draw it at 168px.

The fix has one real constraint: **a second size means a second URL, which means
a second `ArtworkCache` entry and a second download for the same artwork.** So it
cannot simply be per-call-site. The shape that works is a small number of named
sizes (thumb / tile / hero) chosen so the common screens share one, with the
tradeoff written down at `MusicKitCatalogSource.swift:27` where the constant
lives.

**MusicKit hands over the colours, and using them requires no pixel sampling.**
`Artwork.backgroundColor`, `.primaryTextColor`, `.secondaryTextColor`,
`.tertiaryTextColor`, `.quaternaryTextColor` are all `CGColor?`, all iOS 15 /
macOS 12 — below the floor. Reading metadata Apple ships is not "modifying
MusicKit Content", and a gradient drawn *behind* the hero composites nothing onto
it — the same reasoning that already licenses the `.clipShape` and `.shadow` at
`NowPlayingView.swift:210-214`. `CatalogItem` currently carries only
`artworkURL`, so carrying a colour through would mean one added field in
`CatalogKit`.

---

## 5. What not to do

Assessed and rejected. Recorded so the next run does not re-open them.

- **The `NowPlaying` framework (WWDC26 312).** iOS 27 / macOS 27 and **absent from
  `iPhoneOS26.5.sdk`** — all 277 frameworks enumerated, it is not there. Xcode
  26.6 cannot compile against it even behind `#available`, because `#available`
  gates execution, not linkage. It is also architecturally irrelevant:
  `MediaSession` exists so an app that *renders its own audio* can publish
  metadata and commands. This app renders nothing —`ApplicationMusicPlayer` hands
  playback to the Music stack, which owns the session and publishes it already.
  Publishing alongside it would double-publish the same playback.
- **`UIDesignRequiresCompatibility`.** See §1.
- **A `TabView` added to reach `.tabViewBottomAccessory`.** See §4.1.
- **`.navigationTransition(.zoom)` for the player.** See §4.2. It remains a good
  fit for *tile → album push* (§6), where there is a real presentation.
- **A sidebar in the kid player.** See §3.8.
- **Forced dark mode.** See §3.5.
- **A stretchy overscroll header.** See §4.3.
- **Retracting the bottom bars on scroll.** See §4.3.
- **Custom headphone-disconnect handling.** `AVAudioSession.h` in SDK 26.5: "Starting
  in iOS 17, by default Now Playing sessions will be interrupted if they are active
  when a route change occurs because of a disconnect event." `ApplicationMusicPlayer`
  *is* that session, so iOS 17+ pauses for free. Adding an observer would be wrong
  twice: `AVAudioSession.sharedInstance()` in *this* process is not the session
  rendering the audio, and any auto-resume path would restart playback **without a
  policy verdict** — `Session.resume()` re-takes no verdict today. The HIG posture
  is the right one anyway: pause on disconnect, never auto-resume.
- **`backgroundExtensionEffect()` on the album hero.** It extends a view's *own*
  content outward to fill the container — it is for full-bleed background imagery.
  The album cover is a centred, clipped, rounded 280pt square: there is nothing for
  it to extend into and the clip shape defeats it. A blurred, scaled copy behind a
  scrim is the honest recipe for that look.
- **`.animation(.smooth, value:)` to animate a `switch` between branches.** It
  compiles and silently does nothing. A branch swap needs `.transition` on the
  branches and the value change inside `withAnimation`, or shared identity.

---

## 6. Recommendations, in order

Grouped so each group is a coherent commit. Tier tags as §1.

**Group A — identity (Floor).** Three colour sets + the build setting;
`.fontDesign(.rounded)` on the kid subtree with `.fontDesign(nil)` on the admin
sheet; fix the four `.font(.system(size:))` sites per §3.4.

**Group B — motion vocabulary (Floor).** One `enum Motion`; replace all eight
existing animation call sites; Reduce Motion honoured in one place;
`.contentTransition(.symbolEffect(.replace))` on both play/pause glyphs; one
shared pressed-state `ButtonStyle`.

**Group C — the cheap correctness pass (Floor).** 44pt hit targets on the heart
and on the bar's transport buttons; accessibility labels on the lock and ellipsis
buttons; `@ScaledMetric` on the tile width and the two fixed heights;
`ContentUnavailableView` for the parent-side empty states; skeletons instead of
bare spinners on the four detail screens.

**Group D — scroll and shelves (Floor).** `.scrollTargetBehavior(.viewAligned)` +
`.scrollTargetLayout()` + `.contentMargins` on every shelf; consolidate
`SongRowMetrics` / `AlbumTrackMetrics`; name the corner radii and the tile width.

**Group E — the title hand-off (Floor).** §4.3, Album and Artist only.

**Group F — artwork (Floor).** §4.4: named sizes, and the `CatalogKit` field if
the artwork-derived gradient is wanted.

**Group G — the floating capsule (Gated).** §4.1. This is the first group that
needs `#available`, so it is also where the house fence style gets set.

**Group H — the morph (Floor).** §4.2. Last because it is the only genuinely
novel work, and because everything above makes it easier to see whether it landed.

**Optional, iOS 18 only:** `.matchedTransitionSource` +
`.navigationTransition(.zoom)` on tile → album/artist pushes. Real presentation,
real API, correct use — but `@available(macOS, unavailable)`, so it is an
iOS-only enhancement with a plain push underneath.

---

## 7. Verification, under the no-simulator rule

Per `CLAUDE.md`, do not run the simulator *to look at the app* without the
maintainer asking for it. A headless probe behind a launch argument is always
legitimate. The screenshots that produced the "observed" notes in this file were
taken on 2026-08-03 with explicit permission.

The gates are:

```sh
for p in Packages/*/; do swift test --package-path "$p"; done
cd Apps/AuralSandbox
xcodebuild build -scheme AuralSandbox -sdk iphonesimulator
xcodebuild build -scheme AuralSandbox -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

**`CODE_SIGNING_ALLOWED=NO` is what makes the macOS gate usable again, and it is
worth keeping.** `CLAUDE.md` records that the plain macOS app build now fails on
provisioning (the iCloud entitlements moved the Mac target onto a real
development profile this machine is not registered on) and says not to chase it.
That is right — but dropping the macOS build entirely would silently lose the
*availability* check, and there is no substitute for it. Verified on 2026-08-03:
with `CODE_SIGNING_ALLOWED=NO` the macOS build reaches `** BUILD SUCCEEDED **`
on a clean tree, so it still compiles every line and still type-checks every
`@available`.

**The build gate is stronger than it looks — this was proved, not assumed.** An
unfenced `.scrollEdgeEffectStyle(.soft, for: .bottom)` at file scope produces:

```
error: 'scrollEdgeEffectStyle(_:for:)' is only available in iOS 26.0 or newer
```

Not a warning. `IPHONEOS_DEPLOYMENT_TARGET = 17.0` is what the checker compares
against and the iOS 26.5 SDK supplies the annotation, so **every gated
recommendation in this file is enforced by the build, not merely advised.**

**Run both commands, always — re-proved on 2026-08-03 against this exact
toolchain.** A `ZZProbe.swift` carrying an unfenced
`.scrollEdgeEffectStyle(.soft, for: .bottom)` inside a `#if os(macOS)` branch
gave:

| Gate | Result |
| --- | --- |
| `-sdk iphonesimulator` | `** BUILD SUCCEEDED **` — did **not** catch it |
| `-destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | `error: 'scrollEdgeEffectStyle(_:for:)' is only available in macOS 26.0 or newer` |

A `#if os(macOS)` branch is invisible to the iOS gate and a `#if os(iOS)` branch
is invisible to the macOS one — and `NowPlayingBar.swift:139-159`,
`KidPlayerModel` and `PlayerExpansion` all have such branches. Dropping the macOS
gate means those branches are compiled by nothing.

**`#Preview` bodies are compiled and availability-checked by both gates.** Also
proved: an unfenced iOS 26 call inside a `#Preview` failed both builds, attributed
to the macro expansion. So a preview catalogue is not only the maintainer's
looking-glass — it is a **compile-time regression net over every component's
initializer and every symbol it names**.

**Adding a preview file needs no `pbxproj` edit.** The target uses
`PBXFileSystemSynchronizedRootGroup` (objectVersion 77) with zero exception sets,
so a `.swift` file dropped into `Apps/AuralSandbox/AuralSandbox/` joins the target
automatically. Verified.

**Previewable today with plain values, no seam:** `SongRow`, `Tile`,
`PlaylistCard`, `HomeSkeleton`, `ShelfHeader`, `ArtistChip`, `KidSearchBar`,
`SearchingView`. Between them these carry the artwork placeholder, the tile
geometry, the row metrics, both bar rows, every scattered corner radius and the
`.repeatForever` animation — most of the styling surface.

**Not previewable today:** anything taking `Session` or `KidPlayerModel` —
`TileCell`, `TileShelf`, `TileGrid`, `SongList`, `RecentRows`, `ContainerRow`,
`HeartButton`, `NowPlayingBar`, `NowPlayingView`, `ExpandedPlayer`, `KidHomeView`.
`Session.init(passcodes:)` builds an on-disk SwiftData container, an
`ApplicationMusicPlayer`, two `UserDefaults` stores, and *inserts and saves* a
Family and a Kid. Only `passcodes` is injectable, and `player` is typed
concretely (`let player: MusicKitPlayer`) rather than `any CatalogPlayer`.

The seam is smaller than it sounds: `FamilyStore.inMemoryContainer()` already
exists. A designated `Session.init` taking `container:`, `source:`, `player:`,
`librarySource:` with today's values as defaults, plus widening `player` to
`any CatalogPlayer`, is hours not days — and it unlocks previews for the player,
which is the screen most of this file is about.

**Preview traits worth having in the catalogue:** `.sizeThatFitsLayout`,
`.fixedLayout`, and environment overrides for `\.colorScheme = .dark`,
`\.dynamicTypeSize = .accessibility5`, `\.layoutDirection = .rightToLeft`.

**Grep gates** — each should return nothing once its group lands:

```sh
grep -rn '\.font(\.system(size:' Apps/            # Group A (2 decorative sites stay, comment them)
grep -rn 'easeInOut' Apps/                        # Group B
grep -rn '\.background(\.bar)' Apps/              # Group G (2 admin sites stay)
grep -c '150' Apps/AuralSandbox/AuralSandbox/KidHomeView.swift   # Group D: 4 -> 1
```

**Seen on a running build (iPhone 17 Pro simulator, iOS 26.5, 2026-08-03).**
Liquid Glass is confirmed active — the toolbar lock button renders as a circular
glass control. The tint is confirmed stock system blue in both appearances.
Dark mode is confirmed correct: every semantic style resolves and nothing is
hardcoded. The bottom chrome is confirmed a full-width flush slab with a visible
seam. The AX5 artwork collapse (§3.4) was *found* this way, not predicted. The
double-darkening claim was *refuted* this way (§4.1). MusicKit worked in the
simulator against a signed-in account, contrary to the assumption that nothing
could be fetched.

**Driving the simulator, once permissions are granted.** Terminal needs
Automation (System Events) *and* Accessibility. Get the device rect from the
window's `AXGroup` rather than guessing at the title bar — it reports the exact
logical screen:

```sh
osascript -e 'tell application "System Events" to tell process "Simulator" \
  to tell window 1 to get {position, size} of (first UI element whose role is "AXGroup")'
# → 844, 119, 402, 874    (origin, then device points)
```

Screenshot pixels ÷ 3 = device points; add the origin for screen coordinates.
**`activate` and `click` must be in the same `osascript` invocation with a delay
between them** — clicking from a separate call silently does nothing, which reads
exactly like a dead control and cost two false findings here.

**Still not verified.** The drag expansion (a click cannot express a drag), the
Album and Artist screens and their empty navigation bar, search results, and
every scrolled state.

**Not verifiable from this side at all.** How the motion *feels* — no screenshot
answers that. Whether the morph's cover lands exactly on the hero (§4.2 fix 2).
Whether the opacity-0 hero slot still takes the album tap (§4.2). Whether the
capsule's clipped corners mis-catch a tap (§4.1). The scroll-edge-effect band
height under the floating capsules (§4.1). Every contrast judgement, which needs
a real display. And anything about behaviour on the real under-13 account.

**The hero artwork softness (§4.4) is now measured, not inferred** — 2.1× upscale
on an iPhone 17 Pro, visible as interpolation blur in the cover's fine text.

---

## 8. Unverified

- All point values in §4.1 except the structure. Apple publishes no metrics for
  the Music mini player.
- Whether `AVRoutePickerView` can reroute audio this app does not render.
  `AVRoutePickerView.player` is `API_UNAVAILABLE(ios)` and the header's discussion
  names `AVPlayer` and `AVSampleBufferAudioRenderer` — neither describes
  `ApplicationMusicPlayer`. Device question, belongs in *Open Questions*.
- Everything about iOS 27 / macOS 27. They exist (WWDC 2026-06-08) and Liquid
  Glass is reported to have been retuned, but the installed SDK is 26.5 and
  nothing from 27 is reachable. **Nothing in this file should be assumed
  forward-compatible.**
- Whether the app should enter the Kids Category, which changes what the parent
  admin is allowed to do. Still open in the wiki.
