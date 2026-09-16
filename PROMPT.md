I'm Miel — not a developer, I can't read or write code. You're taking over as senior iOS/Swift developer
on **AuraLink**, an iOS app that streams Google Maps navigation to my CFMoto Aura 150 motorcycle's
dashboard over Wi-Fi, so I don't need to buy CFMoto's expensive T-Box subscription hardware. This is a
port of an existing, mature, bike-tested Android app called OpenCfMoto (AGPLv3, github.com/zanderp/
open-cfmoto) — the hard reverse-engineering work is already done and documented; you're porting proven
protocol knowledge to Swift, not reverse-engineering from scratch.

This folder is a complete handoff package another Claude session prepared for you. **Read these in
order before writing any code:**

1. `docs/00-README-HANDOFF.md` — project goal, ground rules already decided (don't re-litigate them),
   how I want to work with you.
2. `docs/01-PROTOCOL-REFERENCE.md` — byte-exact wire protocol spec for talking to the bike. This is the
   core value of the whole project; treat it as verified ground truth.
3. `docs/02-IOS-ARCHITECTURE-PLAN.md` — target Swift architecture, a file-by-file map of what ports
   directly from the Android Kotlin source vs. what needs an iOS-native rewrite, the CI/CD setup, and a
   phased build order.
4. `docs/03-CURRENT-STATE.md` — exactly what already exists in this scaffold (a buildable but empty
   shell + full CI config) vs. what's 100% unwritten. Don't assume anything beyond what this file says
   exists.
5. `reference/android-source/java/` and `reference/android-docs/` — the full original Android
   implementation. This is ground truth when anything above is unclear or ambiguous — go read the actual
   Kotlin, don't guess.

**What I need from you:** Build the complete app, end to end, following the phased order in doc `02`.
I want a finished product I can install via TestFlight and start testing on my actual bike — I'd rather
get the whole thing built first and tweak it after real-world testing than review it piece by piece as
you go. Use your own judgment on implementation details; I'm not going to be able to answer technical
questions, so make the call yourself and note anything important in your commit messages or a running
decision log. Only stop and ask me directly when a decision costs money, requires me to create an
account/click through some Apple/Google web console myself, or is genuinely a product/taste choice (not
a technical one) — like "what should the app icon look like" or "what should the button layout be."

A few things to keep in mind: I have zero ability to debug Xcode, read a stack trace, or interpret build
output — everything needs to build and test itself via the GitHub Actions CI already set up in
`.github/workflows/build.yml`, and if I ever need to give you feedback it'll be either "it crashed" /
plain description of what happened on the bike, or an exported log file from the app itself (the app
needs a working Share Log feature early, not as an afterthought — the Android app's `LogBus` pattern in
doc `02` shows why). I don't have the bike in front of me right this moment either — build as much as
possible against the documented protocol and a simulator/test-pattern video source first, and flag
clearly in your progress notes which parts are genuinely unverified until we do a real bike test session
together.

Go ahead and start — set up your own task list, work through the phased build order, and keep building
until the app is feature-complete per doc `02`'s scope (protocol, video pipeline, MapKit navigation,
trip logging, handlebar button support, settings/multi-bike profiles, and the SwiftUI UI for all of it).
Push commits as you go so I can see progress even though I can't review the code myself.
