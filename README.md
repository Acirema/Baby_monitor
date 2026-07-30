yy# Baby Monitor (Flutter)

A Flutter app that can act as either a **Server** (broadcasts camera + microphone,
detects sound and optionally motion) or a **Client** (views the stream and gets a
pop-up alert whenever the server detects sound/motion).

## Multiple clients

The server accepts multiple simultaneous clients. It's a **mesh**, not a relay/SFU: every connected client gets its own direct WebRTC connection to the server, all fed from the same camera/mic tracks, and each goes through the same access-code handshake independentl.

## Security model 

1. **Access-code handshake.** The server displays (or lets you set) a 6-digit access code. When a device connects to the signaling port, it must prove — via a PBKDF2/HMAC-SHA256 challenge-response in
   `lib/services/secure_channel.dart` — that it knows the code, *without ever transmitting the code itself*.
2. **Encrypted signaling + encrypted media.** All SDP/ICE messages are encrypted with AES-256-GCM under a key derived from the access code, so a passive network sniffer sees only ciphertext, not connection details.
   The actual video/audio stream is carried over WebRTC, which mandates DTLS-SRTP encryption between the two peers regardless — so once the access-code gate is passed, the media itself is already protected from eavesdroppers on the LAN.

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

To get a runnable project:

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

## Generate Android apk

```bash
flutter build apk --release 
```
### Required permissions

**Android** — add AndroidManifest to `android/app/src/main/AndroidManifest.xml`
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


