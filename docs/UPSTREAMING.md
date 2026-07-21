# Upstreaming the macOS Core Audio tap backend

This fork adds native macOS system-audio capture to projectMSDL
(`src/AudioCaptureImpl_CoreAudioTap.{h,mm}`). This note records **how** we would
contribute it back to [projectM-visualizer/frontend-sdl-cpp](https://github.com/projectM-visualizer/frontend-sdl-cpp)
if we chose to, and **whether it's a good idea**. We are *not* opening a PR right now.

## Is it a good idea?

**Short answer: yes, and the required delta is smaller than it first appears.** A
minimal, well-guarded PR could be acceptable; most of the "hardening" below is
optional polish, not a blocker. Still best to open a *draft* PR first to let the
maintainers set the bar.

**Why it's worth doing**

- Real user need. Today macOS users must install BlackHole (or similar) and route
  audio through a virtual device just to visualize what's playing. This removes that
  entirely.
- It fits the existing architecture. The project already has an OS-specific capture
  seam (`AUDIO_IMPL_HEADER`) with a WASAPI loopback backend on Windows. This is the
  direct macOS analogue — no new abstractions, one more sibling implementation.
- It's the "right" native mechanism (Apple's Core Audio process-tap API), not a hack.

**What upstream actually requires (checked, not assumed)**

I inspected upstream's build config and CI before writing this:

- `CMAKE_OSX_DEPLOYMENT_TARGET` is **not set anywhere** — there is no declared minimum
  macOS version.
- CI (`buildcheck.yaml` and `release-macos.yaml`) builds and tests **only on
  `macos-latest`**. There is no test matrix for older macOS versions.

So the "must support old macOS" concern is weaker than it sounds — upstream doesn't
test or advertise old-OS support today. Whether < 14.4 matters is really **a question
for the maintainers**, not a settled requirement. Given macOS 14.4 shipped in early
2024, a policy of "system-audio capture requires 14.4+, otherwise fall back to mic"
is very plausible to be accepted as-is.

**The one thing worth doing regardless: an `@available` guard.**

The process-tap symbols are weak-linked and only present at runtime on macOS 14.4+.
If the release binary (built on `macos-latest` with no deployment floor) is ever run
on macOS 13 and calls the tap unconditionally, it will crash with a missing-symbol
error. Wrapping the tap setup in `if (@available(macOS 14.4, *)) { ... }` — a few
lines — prevents that. On older systems it can fall back to the existing SDL (mic)
backend or simply log and idle. This is cheap insurance and good practice, and is the
*only* backward-compat work that's clearly justified.

**Optional polish (nice-to-have, not blockers)**

- **Device list.** v1 exposes a single synthetic "System Audio" device. Coexisting
  with selectable input devices (mics), and eventually per-process capture, would
  match the richer lists the WASAPI/SDL backends return — but a single-source PR is
  still useful.
- **Robustness parity with WASAPI.** Handle default-output-device changes (re-target
  the aggregate device) and the documented "all-zero samples after a long session"
  recovery (recreate both tap and aggregate). Worth doing eventually; not required for
  a first useful PR.
- **Signing / distribution.** Capture needs a signed bundle (TCC keys the grant to a
  signing identity). Upstream already has a full notarization pipeline
  (`release-macos.yaml`); it would just need the `NSAudioCaptureUsageDescription` key
  (added here) and possibly an audio entitlement — a coordination item, not new
  engineering.
- **Review niceties.** Map `OSStatus` codes to readable log strings; confirm the
  `CATapDescription` API used is non-deprecated for the maintainers' SDK.

**Effort estimate:** the core capture works and is verified. A PR-ready version is
realistically **the current code + an `@available` guard + a maintainer conversation**
— modest. Everything else is incremental follow-up.

## How we would do it

1. **Open an issue / draft PR early.** Describe the approach (process tap + private
   aggregate device, SDL fallback for < 14.4) and get maintainer sign-off before
   polishing. Reference Apple's
   [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps)
   and the [insidegui/AudioCap](https://github.com/insidegui/AudioCap) sample.

2. **Restructure backend selection for runtime fallback.** On Darwin, compile *both*
   `AudioCaptureImpl_CoreAudioTap` and the SDL backend, and select at runtime with an
   `@available(macOS 14.4, *)` check (plus a config override). This keeps older macOS
   working. This likely means a small factory instead of the compile-time
   `AUDIO_IMPL_HEADER` macro on macOS.

3. **Flesh out the device list** to include input devices and (optionally) per-process
   entries, so `AudioDeviceList()` / `NextAudioDevice()` behave like the other
   backends rather than returning a single synthetic device.

4. **Add resilience:** default-device-change handling and tap/aggregate teardown +
   recreate on the zero-sample failure mode.

5. **Wire signing/permissions into packaging** with the maintainers (entitlements,
   notarization, the Info.plist usage string — already added here).

6. **Split the contribution from fork-only bits.** `scripts/install-macos.sh`,
   `docs/superpowers/`, and this file are fork-specific and would be excluded from the
   PR. Only the backend, the CMake changes, and the Info.plist key belong upstream.

7. **Rebase onto upstream `master`**, since this fork was branched from a specific
   commit and upstream may have moved.

## Contribution checklist (if/when we do it)

Required for a first PR:

- [ ] Draft PR opened, minimum-macOS policy agreed with maintainers
- [ ] `@available(macOS 14.4, *)` guard around tap setup (fall back to SDL/mic or idle)
- [ ] Fork-only files excluded from the PR (`scripts/`, `docs/superpowers/`, this file)
- [ ] Rebased on upstream `master`; CI green

Optional follow-up (only if maintainers want it):

- [ ] Device list includes inputs (and optionally per-process)
- [ ] Default-device-change handling
- [ ] Zero-sample recovery (recreate tap + aggregate)
- [ ] `OSStatus` → readable log messages
- [ ] Packaging: entitlements + notarization + usage string
