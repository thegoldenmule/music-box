# Music Box

A native iOS and Mac app that lets kids explore music inside walls the parent
sets. It plays from Apple Music through MusicKit, so the catalog is complete; we
control which parts of it a kid can reach.

Design docs live in the **Aural Sandbox** wiki workspace, not in this repo.

## Layout

```
Packages/     local Swift packages, one per major piece
  PolicyEngine/   what a kid may see or play — pure logic, no MusicKit, no UI
  CatalogKit/     the only layer that imports MusicKit
Apps/         app targets (Xcode projects)
Tools/        spikes and throwaway probes
```

Packages are plain SwiftPM and build from the command line. Anything that needs
an Xcode project (app targets, entitlements, signing) lives under `Apps/`.

`CatalogKit` depends on `PolicyEngine`; nothing depends on `CatalogKit` yet.

## Building

```sh
for p in Packages/*/; do swift test --package-path "$p"; done
```

## Platform floor

**iOS 17, macOS 14.** Set by what we already depend on, not by preference:

| Floor | Set by |
| --- | --- |
| iOS 16 / macOS 14 | `MusicLibraryRequest` and `MusicLibrarySearchRequest`, needed for library seeding |
| iOS 17 / macOS 14 | SwiftData, which the storage design commits to |
| macOS 14 | `ApplicationMusicPlayer` — no in-app playback below it |

iOS 17 is the lowest version consistent with those, and it still runs on 2018
hardware — an iPad 6th gen or an iPhone XS. That matters, because the device this
app lands on is usually a hand-me-down.

Newer APIs are adopted opportunistically behind `if #available` rather than by
raising the floor. `MusicCatalogResourceRequest.options = [.findEquivalents]`
(iOS 26.4+) is the current example.
