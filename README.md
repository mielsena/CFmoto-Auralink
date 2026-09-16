# AuraLink

Wireless Google Maps on a CFMoto Aura 150's dashboard over Wi-Fi — no T-Box subscription. An iOS port of
[OpenCfMoto](https://github.com/zanderp/open-cfmoto) (AGPLv3), which does the same for Android via a
fully reverse-engineered Carbit EasyConnect / PXC protocol.

**Status: early scaffold, not yet functional.** See `docs/03-CURRENT-STATE.md` for exactly what exists
vs. what's still to build.

## Start here

If you're picking this project up (human or agent), read in this order:

1. `docs/00-README-HANDOFF.md` — orientation, ground rules, how the project owner (not a developer)
   wants to work.
2. `docs/01-PROTOCOL-REFERENCE.md` — the byte-exact wire protocol reference.
3. `docs/02-IOS-ARCHITECTURE-PLAN.md` — target Swift architecture, file-by-file port mapping, build order.
4. `docs/03-CURRENT-STATE.md` — what's already scaffolded in this repo.
5. `reference/android-source/` and `reference/android-docs/` — the original, bike-tested Android
   implementation this is ported from. Ground truth when anything above is ambiguous.

## Building locally (requires a Mac with Xcode)

```sh
brew install xcodegen
xcodegen generate
open AuraLink.xcodeproj
```

Or from the command line:

```sh
xcodebuild build -project AuraLink.xcodeproj -scheme AuraLink -destination "generic/platform=iOS Simulator"
```

## CI

GitHub Actions (`.github/workflows/build.yml`) builds and tests on every push, and on a `v*` tag (or
manual dispatch) builds, signs, and uploads to TestFlight via fastlane. See
`docs/02-IOS-ARCHITECTURE-PLAN.md` → "CI/CD" for the one-time manual setup this requires in App Store
Connect.

## License

AGPL-3.0-or-later — see `LICENSE` and `NOTICE`. This is a derivative of OpenCfMoto's AGPLv3 protocol
implementation; the same license carries forward.
