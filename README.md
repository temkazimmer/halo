# Halo

A local-only macOS screen recorder with a shaped camera bubble.

Records the screen with a live webcam feed composited on top, entirely on this
Mac. No accounts, no upload, **no network calls at all**. The differentiator is
rich parametric control over the camera bubble's shape — circle, squircle,
rounded rect, polygon, star, blob — each with live-tweakable parameters,
borders, shadows and feathering.

The full brief lives in `HALO_PLAN.md` in the Open knowledgebase vault
(`20 Projects/screencapture/`).

## Requirements

- macOS 15.0 or later (deployment target)
- Xcode 26 with the Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`)

## Layout

```
Halo/                     app target — thin
  HaloApp.swift           @main, MenuBarExtra + main window
  Permissions/            TCC state, onboarding, relaunch flow
  Views/                  control panel, source picker
Packages/HaloCore/        local SPM package — the testable core
  Sources/HaloCapture/    shareable content, capture (later phases)
```

`HaloCore` is one umbrella product so later phases can add modules without
touching the Xcode project. Import the *module* (`HaloCapture`), not the product.

The app target uses an Xcode 16+ synchronized folder group: files added under
`Halo/` are picked up automatically, with no project-file edit.

## Build

```
xcodebuild -project Halo.xcodeproj -scheme Halo -configuration Debug build
swift test --package-path Packages/HaloCore
```

## Non-negotiables

1. **100% local.** Zero network requests — no analytics, no update check, no
   crash reporter.
2. **Sandboxed from commit #1.** See `Halo/Halo.entitlements`; add nothing to it
   without reading §7.1 of the plan first.
3. **WYSIWYG preview.** One compositor, two destinations (screen + encoder).

## Status

- [x] Phase 0 — Scaffold, sandbox, permissions, relaunch flow, display list
- [ ] Phase 1 — Screen → mp4, HEVC, correct colour and timing
- [ ] Phase 2 — System audio + mic, mixed to one track
- [ ] Phase 3 — Camera capture + floating click-through bubble
- [ ] Phase 4 — Metal compositor, WYSIWYG preview
- [ ] Phase 5 — Shape system: 6 shapes, SDF masks, inspector, presets
- [ ] Phase 6 — Menu bar UI, recording indicator, hotkey, save panel, icon
