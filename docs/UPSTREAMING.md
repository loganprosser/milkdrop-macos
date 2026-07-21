# Upstreaming the macOS Core Audio tap backend

This fork adds native macOS system-audio capture to projectMSDL
(`src/AudioCaptureImpl_CoreAudioTap.{h,mm}`). This note records **how** we would
contribute it back to [projectM-visualizer/frontend-sdl-cpp](https://github.com/projectM-visualizer/frontend-sdl-cpp)
if we chose to, and **whether it's a good idea**. We are *not* opening a PR right now.

## Is it a good idea?

**Short answer: yes, it's worth upstreaming — but only after a hardening pass.** It
should go up as a *draft* PR first to agree on the approach before polishing.

**Why it's worth doing**

- Real user need. Today macOS users must install BlackHole (or similar) and route
  audio through a virtual device just to visualize what's playing. This removes that
  entirely.
- It fits the existing architecture. The project already has an OS-specific capture
  seam (`AUDIO_IMPL_HEADER`) with a WASAPI loopback backend on Windows. This is the
  direct macOS analogue — no new abstractions, one more sibling implementation.
- It's the "right" native mechanism (Apple's Core Audio process-tap API), not a hack.

**Why not to just PR what we have now**

The current backend is a deliberately minimal v1. Before upstream would (or should)
accept it, several gaps matter more for a shared project than for a personal build:

1. **Backward compatibility is the big one.** The process-tap API is macOS 14.4+.
   Upstream supports older macOS, but our `src/CMakeLists.txt` unconditionally selects
   the tap backend on *all* Darwin. Upstream needs a runtime fallback: build both the
   Core Audio and SDL backends on macOS and choose at runtime (`if (@available(macOS
   14.4, *))`), falling back to SDL (mic) on older systems. This is the main
   engineering work and the most likely review blocker.
2. **Device list.** v1 exposes a single synthetic "System Audio" device. Upstream
   users will expect the tap to coexist with selectable input devices (mics) and,
   ideally, per-process capture — matching the richer device lists the WASAPI/SDL
   backends return.
3. **Robustness the WASAPI backend already has.** Handle default-output-device
   changes (re-target the aggregate device), and implement the documented
   "all-zero samples after a long session" recovery (destroy + recreate both tap and
   aggregate). WASAPI does hot-plug handling via notification callbacks; a serious
   macOS backend should be comparable.
4. **Signing / distribution.** Capture requires a signed bundle (TCC keys the grant to
   a signing identity). Upstream's release/notarization pipeline and entitlements
   (hardened runtime) would need the `NSAudioCaptureUsageDescription` key and possibly
   an audio-input entitlement wired in — coordinate with maintainers.
5. **Review niceties.** Map `OSStatus` codes to readable strings in logs; confirm the
   `CATapDescription` initializers/properties used are the non-deprecated ones for the
   maintainers' minimum-supported SDK.

**Effort estimate:** the core capture works and is verified. The remaining work is
mostly (1) and (3) — call it a few focused sessions plus review iterations.

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

- [ ] Draft PR opened, approach agreed with maintainers
- [ ] Runtime SDL fallback for macOS < 14.4
- [ ] Device list includes inputs (and optionally per-process)
- [ ] Default-device-change handling
- [ ] Zero-sample recovery (recreate tap + aggregate)
- [ ] `OSStatus` → readable log messages
- [ ] Non-deprecated `CATapDescription` API confirmed for min SDK
- [ ] Packaging: entitlements + notarization + usage string
- [ ] Fork-only files excluded from the PR
- [ ] Rebased on upstream `master`; CI green
