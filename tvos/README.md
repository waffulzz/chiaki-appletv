# chiaki-ng for Apple TV (prototype)

A tvOS frontend for chiaki-ng. It reuses `chiaki-lib` unchanged for discovery, registration and streaming, and adds a SwiftUI app around it.

## Layout

| Path | What it is |
| --- | --- |
| `bridge/` | Small C facade (`chiakitv.h`) over chiaki-lib. Swift only sees this header, because chiaki-lib's own structs change layout with the crypto backend (mbedtls on tvOS). |
| `scripts/build-chiaki-lib.sh` | Cross-compiles chiaki-lib and its dependencies for tvOS device and simulator, merges them into `build/ChiakiTV.xcframework`, then generates the Xcode project. |
| `project.yml` | xcodegen spec for `ChiakiTV.xcodeproj` (generated, not committed). |
| `ChiakiTV/` | The app: console list, registration, settings, logs, and the stream screen. |

How the stream screen works:

- **Video**: chiaki-lib hands over Annex-B H.264/H.265 access units. `VideoRenderer` turns them into `CMSampleBuffer`s and hands them to an `AVSampleBufferDisplayLayer`, which decodes them in hardware.
- **Audio**: chiaki-lib's Opus decoder outputs PCM, which `AudioPlayer` plays through `AVAudioEngine` with at most about 100 ms buffered.
- **Input**: `ControllerInput` maps any GameController gamepad (DualSense, DualShock 4, Xbox, MFi) onto `ChiakiControllerState`. Rumble goes through Core Haptics.

On tvOS the dependencies are built from source. mbedtls handles chiaki's crypto, curl uses Secure Transport, and Opus, libevent, json-c and miniupnpc come in through CMake FetchContent. Nothing is taken from Homebrew.

## Building

Requirements: Xcode with the tvOS SDK, plus:

```bash
brew install cmake ninja protobuf xcodegen
git submodule update --init --recursive
```

Then:

```bash
tvos/scripts/build-chiaki-lib.sh
open tvos/ChiakiTV.xcodeproj
```

To run on a real Apple TV:

1. In Xcode, select the ChiakiTV target, open Signing & Capabilities, and pick your Team. You may need to change the bundle identifier.
2. Pair the Apple TV with Xcode. On the Apple TV, open Settings › Remotes and Devices › Remote App and Devices. In Xcode, open Window › Devices and Simulators.
3. Pick the Apple TV as the run destination and press Run. The first time the app runs, allow Local Network access.

## Using it

1. Your PS5 or PS4 should appear on its own. If it doesn't, use **Add Console by IP Address**. Automatic discovery relies on UDP broadcast, which Apple may limit without the multicast networking entitlement. Adding the console by IP only needs unicast, which always works.
2. Choose the console, then **Register**. On the console, open Settings › System › Remote Play › Pair Device (on PS4: Settings › Remote Play Connection Settings › Add Device). Enter your PSN Account-ID (base64) and the 8-digit PIN.
   - You can look up the Account-ID with chiaki-ng on a computer, or with any PSN Account-ID lookup tool.
   - Typing is easier with the keyboard on a paired iPhone.
3. Choose **Play**. If the console is in rest mode, choose **Wake** first.

Controls while streaming:

| Input | Action |
| --- | --- |
| Options + Create/Share | PS button (tvOS keeps the real PS/Home button for itself) |
| DualSense/DualShock touchpad click | Touchpad button |
| L1 + R1 + L3 + R3, or the Siri Remote's Back button | Opens the disconnect menu, where you can also put the console to rest |

## Debugging

- **Settings › Logs** in the app shows chiaki-lib's log. The same lines go to the system log under the subsystem `chiaki-ng-tv`.
- In Debug builds, launching with `-ChiakiTestVideo /path/to/file.h264` (or `.h265`) plays a raw Annex-B file through the video path, so you can test decoding without a console. The file needs access unit delimiters. For example:

```bash
ffmpeg -f lavfi -i testsrc2=size=1920x1080:rate=60 -t 4 -c:v libx264 -x264-params aud=1 -bsf:v h264_mp4toannexb test.h264
```

## Prototype status

Done and tested in the tvOS simulator:

- chiaki-lib and all its dependencies cross-compile for tvOS (arm64 device and simulator)
- console discovery and wakeup
- session start, failure and teardown
- H.264 and H.265 decoding at 1080p60
- controller mapping

Not tested yet:

- registering and streaming against a real console

Not done yet:

- Remote Play over the internet (PSN holepunch). The library supports it, but the app has no PSN login flow.
- DualSense touchpad touches, motion sensors, adaptive triggers and the microphone
- HDR output for `H.265 HDR`
- An app icon and Top Shelf image
