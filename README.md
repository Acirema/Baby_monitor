# Video Monitor (Flutter)

A Flutter app that can act as either a **Server** (broadcasts camera + microphone,
detects sound and optionally motion) or a **Client** (views the stream and gets a
pop-up alert whenever the server detects sound/motion).

## License

MIT License — see `LICENSE`. This is a permissive license, so you're free to
use, modify, and sell this app or products built on it commercially. Swap
"Your Company/Name" in `LICENSE` and the source file headers for your actual
name/company before shipping. Third-party packages this depends on (WebRTC,
crypto, etc.) carry their own permissive licenses — see the note at the
bottom of `LICENSE`.

## Multiple clients

The server accepts multiple simultaneous clients. It's a **mesh**, not a
relay/SFU: every connected client gets its own direct WebRTC connection to
the server, all fed from the same camera/mic tracks, and each goes through
the same access-code handshake independently. Practically this means:

- The server's upload bandwidth and CPU (video encoding) scale roughly
  linearly with the number of connected clients — fine for a handful of
  viewers, but not meant for broadcasting to dozens. If you need many
  simultaneous viewers, the right next step is routing everyone through a
  media server (SFU) instead of this direct mesh.
- Sound/motion detection runs once, server-side, regardless of how many
  clients are connected, and alerts are broadcast to all of them.
- The server screen lists currently connected clients (by address) with a
  button to disconnect any of them individually.

## Security model (who can see the stream)

Two things protect the video/audio from other people on the same network:

1. **Access-code handshake.** The server displays (or lets you set) a
   6-digit access code. When a device connects to the signaling port, it
   must prove — via a PBKDF2/HMAC-SHA256 challenge-response in
   `lib/services/secure_channel.dart` — that it knows the code, *without
   ever transmitting the code itself*. Anyone who doesn't know the code is
   disconnected before any video negotiation happens, and the server only
   accepts one active session at a time.
2. **Encrypted signaling + encrypted media.** All SDP/ICE messages are
   encrypted with AES-256-GCM under a key derived from the access code, so
   a passive network sniffer sees only ciphertext, not connection details.
   The actual video/audio stream is carried over WebRTC, which mandates
   DTLS-SRTP encryption between the two peers regardless — so once the
   access-code gate is passed, the media itself is already protected from
   eavesdroppers on the LAN.

In short: someone on the same Wi-Fi cannot connect and passively watch the
feed, and cannot sniff the handshake to learn anything useful, because they'd
need the access code to do either. Treat the access code like a password —
share it out of band and rotate it (tap the refresh icon on the server
screen) if you think it's leaked.

## How it works

- **Streaming**: peer-to-peer WebRTC (`flutter_webrtc`) for low-latency video + audio.
- **Signaling**: no external server needed — the app opens a TCP socket
  (port `8888` by default) directly between the two devices to exchange the WebRTC
  SDP offer/answer and ICE candidates (see `lib/services/signaling.dart`), wrapped
  in an access-code-authenticated, AES-256-GCM-encrypted layer
  (`lib/services/secure_channel.dart` — see "Security model" below).
- **Sound detection** (server): microphone decibel level via the `noise_meter`
  package, with an adjustable threshold and a cooldown so one loud sound doesn't
  spam alerts.
- **Motion detection** (server, optional toggle): periodically grabs a frame from
  the local video track, downsizes/grayscales it, and compares it to the previous
  frame. If enough pixels changed beyond the sensitivity threshold, motion is
  reported.
- **Alerts**: sent to the client over a WebRTC data channel (`events`) as small
  JSON messages, independent of the video/audio stream, so alerts arrive even if
  the video is briefly congested.

## Project setup

This repo only contains `lib/` and `pubspec.yaml` — it was written without a
Flutter SDK available in the build environment, so the native `android/`, `ios/`,
etc. folders were not generated. To get a runnable project:

```bash
# 1. Create a fresh Flutter project scaffold
flutter create video_monitor_app
cd video_monitor_app

# 2. Replace the generated pubspec.yaml and lib/ with the ones from this package
cp /path/to/this/pubspec.yaml ./pubspec.yaml
rm -rf lib
cp -r /path/to/this/lib ./lib

# 3. Get packages
flutter pub get
```

### Required permissions

**Android** — add to `android/app/src/main/AndroidManifest.xml` (inside `<manifest>`,
above `<application>`):

```xml
<uses-permission android:name="android.permission.CAMERA"/>
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
<uses-permission android:name="android.permission.ACCESS_WIFI_STATE"/>
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS"/>
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30"/>
```

Also set `minSdkVersion 24` or higher in `android/app/build.gradle`.

**iOS** — add to `ios/Runner/Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>Camera access is needed to stream video.</string>
<key>NSMicrophoneUsageDescription</key>
<string>Microphone access is needed to stream audio and detect sound.</string>
<key>NSLocalNetworkUsageDescription</key>
<string>Used to connect directly to the other device on your network.</string>
```

## Using the app

1. Make sure both devices are on the **same Wi-Fi/local network** (or that the
   server's port `8888` is reachable from the client, e.g. via port forwarding if
   remote).
2. On the device that should broadcast, open the app → **Start as Server**, grant
   camera/mic permissions, then tap **Start Server**. It will show its IP address
   and wait for a client. Optionally toggle **Enable motion detection** and adjust
   thresholds.
3. On the viewing device, open the app → **Connect as Client (viewer)**, type in
   the server's IP address, and tap **Connect**.
4. The client shows the live video/audio. Whenever the server detects sound above
   the threshold (or motion, if enabled), a pop-up banner appears on the client.

## Known limitations / notes

- The signaling socket is plain, unencrypted TCP and assumes direct
  reachability (LAN, VPN, or manual port forwarding). It's intentionally simple
  and self-contained so the app doesn't depend on any external signaling
  service. For internet-wide use behind strict NATs you'd typically add a TURN
  server to the `WebRTCService` ICE server list.
- Only one client per server session is handled at a time in this version;
  extending to multiple simultaneous viewers would mean creating one
  `RTCPeerConnection` per connected client on the server.
- Motion detection relies on `MediaStreamTrack.captureFrame()` from
  `flutter_webrtc`. Availability/performance can vary slightly by platform;
  if a frame grab fails on a given tick it's simply skipped rather than
  crashing the detector.
- `noise_meter` opens its own microphone session independently from the
  WebRTC audio track. This works fine on most devices but if you see audio
  session conflicts on a particular platform, it's the first place to look.
