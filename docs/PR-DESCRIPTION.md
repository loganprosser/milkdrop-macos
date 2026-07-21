# PR: Native macOS system-audio capture via Core Audio process tap

**Draft PR body** — ready to submit against `projectM-visualizer/frontend-sdl-cpp`.
Not yet opened. See "How to open it" at the bottom.

- **Base:** `projectM-visualizer/frontend-sdl-cpp:master`
- **Head:** `loganprosser:macos-system-audio-pr`
- **Suggested:** open as a **draft** to agree on the min-macOS policy before further work.

---

## Title

Add native macOS system-audio capture via Core Audio process tap

## Summary

On macOS, projectMSDL currently uses the generic SDL capture backend, which can only
read input devices (microphones). To visualize what is actually playing, users must
install a virtual loopback driver (BlackHole, etc.) and reroute their output.

This adds a native Core Audio **process-tap** capture backend so macOS can visualize
system audio output directly — no third-party driver — mirroring what the Windows
WASAPI loopback backend already does.

## What's included

- `src/AudioCaptureImpl_CoreAudioTap.{h,mm}` — new Objective-C++ backend implementing
  the existing `AudioCaptureImpl` interface. It attaches a global `CATapDescription`
  to a private aggregate device and forwards PCM to `projectm_pcm_add_float` from the
  Core Audio IO proc. Tap setup is wrapped in `if (@available(macOS 14.4, *))`.
- `src/CMakeLists.txt` — select the Core Audio backend on Darwin (previously macOS
  fell through to the SDL backend); link `CoreAudio`, `AudioToolbox`, `Foundation`.
- `src/resources/Info.plist.in` — add `NSAudioCaptureUsageDescription` (system-audio
  capture is its own TCC category, separate from microphone access).

## Testing

Built and run on macOS 26.5 (Apple silicon). The tap starts at 48 kHz stereo and
delivers nonzero PCM only while system audio is playing (verified with a temporary
peak meter: ~0.00 at idle, 0.15+ during playback). Capture requires the app bundle to
be code-signed (TCC keys the permission to a signing identity); ad-hoc signing is
enough for local testing.

## Open questions for maintainers

1. **Minimum macOS policy.** The process-tap API is 14.4+. This PR currently *replaces*
   the SDL backend on macOS and, on older systems, logs and captures nothing (guarded,
   no crash). If you'd rather not regress mic capture on < 14.4, I'm happy to instead
   compile **both** backends on macOS and pick at runtime (Core Audio tap on 14.4+,
   SDL mic otherwise). Which do you prefer?
2. **Signing / notarization.** The release workflow already signs and notarizes; this
   just needs the new usage-description key (included) and possibly an audio
   entitlement. Anything you want wired in here?

## Possible follow-ups (out of scope for this PR)

- Per-process capture (tap a single app) and a richer device list including inputs.
- Default-output-device-change handling and tap/aggregate recreation on the known
  "all-zero samples after a long session" condition.
- Map `OSStatus` codes to readable log strings.

---

## How to open it

```sh
cd /Users/logan/Documents/dev/milkdrop
gh pr create \
  --repo projectM-visualizer/frontend-sdl-cpp \
  --base master \
  --head loganprosser:macos-system-audio-pr \
  --draft \
  --title "Add native macOS system-audio capture via Core Audio process tap" \
  --body-file docs/PR-DESCRIPTION.md
```

(Drop `--draft` for a normal PR. The `--body-file` will include this whole file; trim
the top matter / "How to open it" section first if you want a cleaner body, or pass
`--body "..."` inline instead.)
