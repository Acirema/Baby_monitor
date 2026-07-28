// Copyright (c) 2026 Your Company/Name.
// Licensed under the MIT License — see LICENSE for details.

import 'package:flutter_webrtc/flutter_webrtc.dart';

class WebRTCService {
  // Public STUN server so the app also works across networks that support
  // basic NAT traversal. On a local LAN it isn't strictly required.
  static const Map<String, dynamic> _rtcConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ]
  };

  static const Map<String, dynamic> _sdpConstraints = {
    'mandatory': {
      'OfferToReceiveAudio': true,
      'OfferToReceiveVideo': true,
    },
    'optional': [],
  };

  static Map<String, dynamic> get sdpConstraints => _sdpConstraints;

  static Future<RTCPeerConnection> createConnection() {
    return createPeerConnection(_rtcConfig);
  }

  /// Captures the camera + microphone for the server (broadcaster) role.
  static Future<MediaStream> getLocalMedia() async {
    final constraints = <String, dynamic>{
      'audio': true,
      'video': {
        'facingMode': 'environment',
        'width': {'ideal': 1280},
        'height': {'ideal': 720},
        'frameRate': {'ideal': 24},
      },
    };
    return navigator.mediaDevices.getUserMedia(constraints);
  }
}
