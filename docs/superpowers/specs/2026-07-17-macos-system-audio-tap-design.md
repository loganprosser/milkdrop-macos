# projectMSDL — Native macOS System-Audio Capture (Core Audio Tap)

**Date:** 2026-07-17
**Status:** Approved, implementing
**Base project:** [projectM-visualizer/frontend-sdl-cpp](https://github.com/projectM-visualizer/frontend-sdl-cpp) (the source behind the `projectMSDL` binary)

## Problem

`projectMSDL` on macOS uses the generic SDL audio-capture backend, which can only
read *input* devices (microphones). To visualize what is actually *playing* on the
Mac (Spotify, browser, etc.), users must install a virtual loopback driver such as
BlackHole and route their output through it. On Windows, by contrast, the app ships
a WASAPI loopback backend that taps system output directly with no extra driver.

This fork adds the macOS equivalent: a native Core Audio process-tap backend so the
app visualizes system audio out of the box, no virtual driver required.

## Goal & Scope

- **Goal:** Capture whole-system audio output natively on macOS and feed it to
  projectM, with no third-party driver.
- **Audience:** Polished, shareable fork — clean enough to potentially upstream as a
  PR. Handle the permission prompt and missing-permission state gracefully; document
  setup and build/signing requirements.
- **v1 capture scope:** Whole system output (all processes). Per-app selection is
  explicitly out of scope for v1, but the design leaves room for it (see Future Work).
- **Platform floor:** macOS 14.4+ (Core Audio process-tap API). Development/target
  machine is macOS 26.5.

## Existing Architecture (the seam we plug into)

`AudioCapture` (`src/AudioCapture.cpp`) is a `Poco::Util::Subsystem` proxy. It
includes an OS-specific implementation header via the `AUDIO_IMPL_HEADER` compile
definition and forwards a small interface to it. The implementation class is always
named `AudioCaptureImpl` and exposes:

- `AudioDeviceList() -> std::map<int, std::string>`
- `StartRecording(projectm*, int audioDeviceIndex)`
- `StopRecording()`
- `NextAudioDevice()`
- `AudioDeviceIndex(int)` / `int AudioDeviceIndex() const`
- `std::string AudioDeviceName() const`
- `FillBuffer()`

`src/CMakeLists.txt` selects the impl:

- **Windows** → `AudioCaptureImpl_WASAPI.{h,cpp}` (loopback, taps system output).
- **else (incl. macOS today)** → `AudioCaptureImpl_SDL.{h,cpp}` (input/mic only).

The audio thread forwards PCM to projectM via `projectm_pcm_add_float(handle, data,
frames, channels)`. The SDL backend does this from an async SDL callback and leaves
`FillBuffer()` as a no-op; we follow that same pattern.

## Design

### New backend files

- `src/AudioCaptureImpl_CoreAudioTap.h` — declares `AudioCaptureImpl` with the exact
  interface above.
- `src/AudioCaptureImpl_CoreAudioTap.mm` — Objective-C++ (`.mm`) because
  `CATapDescription` is an Objective-C class; the file also uses the C Core Audio /
  AudioToolbox APIs.

### CMake

Add a dedicated Darwin branch in `src/CMakeLists.txt` (macOS currently falls into the
generic `else()`):

```cmake
elseif (CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    target_sources(projectMSDL PRIVATE
        AudioCaptureImpl_CoreAudioTap.h
        AudioCaptureImpl_CoreAudioTap.mm)
    target_compile_definitions(projectMSDL PRIVATE
        AUDIO_IMPL_HEADER="AudioCaptureImpl_CoreAudioTap.h")
    target_link_libraries(projectMSDL PRIVATE
        "-framework CoreAudio" "-framework AudioToolbox" "-framework Foundation")
```

The generic `else()` branch remains for Linux/other and keeps using SDL.

### Core Audio tap lifecycle

Based on Apple's "Capturing system audio with Core Audio taps" documentation and the
`insidegui/AudioCap` sample.

1. **Create tap.** Build a `CATapDescription` with
   `initStereoGlobalTapButExcludeProcesses:@[]` (empty exclude list → capture *all*
   system output). Set `isPrivate = YES`, `muteBehavior = CATapUnmuted`, and a name.
   Call `AudioHardwareCreateProcessTap(tapDescription, &tapObjectID)`.
2. **Create private aggregate device.** Build the aggregate dictionary with:
   - `kAudioAggregateDeviceIsPrivateKey = true`
   - `kAudioAggregateDeviceMainSubDeviceKey` = UID of the current default output
     device (the aggregate requires a real output sub-device),
   - `kAudioAggregateDeviceTapListKey` = one entry with `kAudioSubTapUIDKey` = the
     tap description's UUID string and `kAudioSubTapDriftCompensationKey = true`,
   - `kAudioAggregateDeviceTapAutoStartKey = true`.

   Call `AudioHardwareCreateAggregateDevice(dict, &aggregateDeviceID)`.
3. **Query stream format.** Read `kAudioDevicePropertyStreamFormat` (scope
   input/tap) from the aggregate device to get sample rate and channel count for the
   PCM we will receive.
4. **Install IO callback.** `AudioDeviceCreateIOProcIDWithBlock` on the aggregate
   device. The block runs on Core Audio's realtime thread: it reads the first buffer
   from the `AudioBufferList`, and calls `projectm_pcm_add_float(handle, samples,
   frameCount, channels)`. No allocation, locking, or logging inside the block.
   `AVAudioEngine` is deliberately **not** used — it silently ignores tap-backed
   aggregate devices.
5. **Start.** `AudioDeviceStart(aggregateDeviceID, ioProcID)`.

### Teardown (exact reverse; order matters)

`AudioDeviceStop` → `AudioDeviceDestroyIOProcID` →
`AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap`. Both the tap
and the aggregate must be destroyed together on restart (per documented "all-zero
samples" recovery sequence).

### Interface mapping

- `AudioDeviceList()` → v1 returns a single synthetic entry, e.g.
  `{-1, "System Audio (Core Audio Tap)"}`. (Structure kept so per-app entries can be
  added later.)
- `StartRecording(handle, index)` → store handle, run the setup sequence above.
- `StopRecording()` → run teardown.
- `NextAudioDevice()` / `AudioDeviceIndex(int)` → no-op / clamp for v1 (single device).
- `AudioDeviceName()` → the synthetic name.
- `FillBuffer()` → no-op (data is pushed from the IO callback, matching SDL backend).

### Permissions & bundle

- Add `NSAudioCaptureUsageDescription` to `src/resources/Info.plist.in` (its own TCC
  category, distinct from `NSMicrophoneUsageDescription`, which stays for the SDL
  path). macOS shows the prompt the first time the tap starts.
- **Signing:** TCC keys its grant off a stable signing identity. The `.app` must be
  signed (ad-hoc `codesign -s -` is enough for local testing) or the permission
  prompt will not fire and capture yields silence. This is documented in the README.
- Testing reset: `tccutil reset SystemAudioCaptureRequests <bundle-id>` re-arms the
  prompt.

## Error Handling

- Any `AudioHardwareCreate*` failure → log via Poco, tear down whatever succeeded, and
  leave the app running silently (visualizer idles) rather than crashing.
- If the default output device can't be resolved for the aggregate main sub-device,
  fail the same graceful way with a clear log line.
- Guard all teardown on non-null/non-zero IDs so partial-setup failures clean up
  correctly.

## Testing / Verification

- **Build:** `cmake` configure + build of the fork against Homebrew projectM/SDL2/Poco.
- **Unit-testable seam:** interface conformance is compile-checked by the shared
  `AudioCapture.cpp`. The Core Audio path itself is hardware/OS-bound and is verified
  end-to-end, not unit-tested.
- **End-to-end (the real check):** launch the signed `.app`, play audio (e.g. a
  YouTube tab), grant the permission prompt, and confirm the visualizer reacts to
  system audio with nothing playing into the mic and BlackHole absent.
- **Negative:** deny permission → confirm graceful silent idle + a clear log message.

## Future Work (out of scope for v1)

- Per-app capture: enumerate processes with audio, populate `AudioDeviceList()` with
  per-PID entries, and build the `CATapDescription` targeting a specific process.
- Restore SDL/mic capture as a selectable device alongside the system tap.
- Auto-recreate tap+aggregate on the documented "all zeros after long session" bug.

## References

- [Apple: Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps)
- [insidegui/AudioCap sample](https://github.com/insidegui/AudioCap)
- [AudioHardwareCreateProcessTap](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:))
- [AudioHardwareCreateAggregateDevice](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateaggregatedevice(_:_:))
- [NSAudioCaptureUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription)
- [CoreAudio Taps for Dummies](https://www.maven.de/2025/04/coreaudio-taps-for-dummies/)
