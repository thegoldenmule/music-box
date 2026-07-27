# Apps

App targets live here.

```
AuralSandbox/
  AuralSandbox.xcodeproj    hand-written; objectVersion 77, synchronized file groups
  Info.plist                partial — merged with the generated one at build time
  AuralSandbox/             all sources; the target picks them up by folder
```

One Xcode project, iOS and Mac destinations, one SwiftUI codebase. It needs an
Xcode project rather than a bare SwiftPM executable because of entitlements,
signing, the MusicKit capability, and the background audio mode in Info.plist.

Bundle identifier: **`com.thegoldenmule.auralsanbox`**. That spelling is
intentional — it matches the registered App ID, and matching the portal beats
matching the dictionary. It carries the MusicKit capability, the eventual Family
Controls approval and the listing, so it is effectively permanent after launch.

## What the app currently is

Build Stage 2's thin vertical slice, not the product. One screen: search Apple
Music, see what the policy engine let through, see what it blocked and why, flip
the sandbox level, and play a song.

It is **not** the kid player. It deliberately shows the blocked list, the
reasons, and the sandbox controls — all parent-side or debug-side. The point is
to prove the seams meet: MusicKit authorizes, `FilteredCatalog` filters through
`PolicyEngine`, `MusicKitPlayer` plays, and `FamilyStore` records it.

The one product rule it does honor exactly is the important one: `Session.play`
asks `FilteredCatalog.verdict(for:)` again immediately before playback rather
than trusting that the UI only offered allowed things.

The Diagnostics section counts unrated results per search. That is the cheap
version of `Tools/RatingProbe` and the number it shows is research question 1 —
it decides the `UnratedBehavior` default and whether an over-fetch multiplier of
3 is anywhere near right.

## Building

```sh
cd Apps/AuralSandbox

# macOS
xcodebuild build -scheme AuralSandbox -destination 'platform=macOS'

# iOS, compile-only — checks the iOS 17 floor
xcodebuild build -scheme AuralSandbox -sdk iphonesimulator
```

Both are verified. **Building to a device is not**, and cannot be on this
machine yet: `generic/platform=iOS` fails with *iOS 26.5 is not installed*. The
iOS platform component needs installing from Xcode → Settings → Components.
Until then nothing here has run against MusicKit at all.

`DEVELOPMENT_TEAM` is deliberately empty. Set it once in Xcode; automatic
signing does the rest.

## Two build-setting traps, both silent

Neither fails to compile. Both were caught by reading values back out of the
built app, which is the only way to catch them.

**`IPHONEOS_DEPLOYMENT_TARGET` conditioned on the SDK does not apply.** Written
as `IPHONEOS_DEPLOYMENT_TARGET[sdk=iphone*] = 17.0` it silently resolved to
26.5, the SDK's own default — a floor that would strand every device below iOS
26.5. It is set unconditionally now. This is the same failure mode CLAUDE.md
records for the packages declaring iOS 15, just inverted.

**`INFOPLIST_KEY_UIBackgroundModes` is accepted and then dropped.** It shows up
in `xcodebuild -showBuildSettings` and never reaches the generated plist —
background audio normally arrives via Xcode's capability editor writing a real
file. Hence `Info.plist`, which holds that one key and merges with the generated
keys at build time.

That file lives *outside* `AuralSandbox/` on purpose. Inside the synchronized
group it is also copied as a resource, and the build fails with *multiple
commands produce Info.plist*.

## Verify the plist, don't trust the settings

```sh
plutil -p "$(xcodebuild -scheme AuralSandbox -sdk iphonesimulator -showBuildSettings \
  | awk '/BUILT_PRODUCTS_DIR/{print $3}')/AuralSandbox.app/Info.plist"
```

Read it with `plutil -p`. **Not** `plutil -extract KEY raw FILE` — without
`-o -` that rewrites the file in place, so checking a key destroys the thing
being checked.
