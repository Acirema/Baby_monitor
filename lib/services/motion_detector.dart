// Copyright (c) 2026 Your Company/Name.
// Licensed under the MIT License — see LICENSE for details.

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:image/image.dart' as img;
import 'dart:typed_data';
/// Grabs still frames from the local video track at a fixed interval and
/// compares a down-scaled, grayscale version against the previous frame.
/// If enough pixels changed beyond [pixelDiffThreshold], motion is reported.
///
/// Note: [MediaStreamTrack.captureFrame] support can vary slightly by
/// platform/version of flutter_webrtc. If frame capture throws on a given
/// platform, that tick is simply skipped rather than crashing the app.
class MotionDetector {
  final MediaStreamTrack videoTrack;
  final double sensitivity; // fraction (0..1) of changed pixels to trigger
  final int pixelDiffThreshold; // per-pixel luminance delta considered "changed"
  final Duration interval;
  final Duration cooldown;
  final VoidCallback onDetected;

  Timer? _timer;
  img.Image? _previousFrame;
  DateTime _lastTrigger = DateTime.fromMillisecondsSinceEpoch(0);
  bool _busy = false;

  MotionDetector({
    required this.videoTrack,
    required this.onDetected,
    this.sensitivity = 0.03,
    this.pixelDiffThreshold = 25,
    this.interval = const Duration(milliseconds: 700),
    this.cooldown = const Duration(seconds: 2),
  });

  void start() {
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    try {
      final ByteBuffer buffer = await videoTrack.captureFrame();
      final bytes = buffer.asUint8List();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        _busy = false;
        return;
      }
      final small = img.copyResize(decoded, width: 80);
      final gray = img.grayscale(small);

      if (_previousFrame != null &&
          _previousFrame!.width == gray.width &&
          _previousFrame!.height == gray.height) {
        int changed = 0;
        final total = gray.width * gray.height;
        for (int y = 0; y < gray.height; y++) {
          for (int x = 0; x < gray.width; x++) {
            final l1 = img.getLuminance(gray.getPixel(x, y));
            final l2 = img.getLuminance(_previousFrame!.getPixel(x, y));
            if ((l1 - l2).abs() > pixelDiffThreshold) changed++;
          }
        }
        final ratio = changed / total;
        if (ratio >= sensitivity) {
          final now = DateTime.now();
          if (now.difference(_lastTrigger) > cooldown) {
            _lastTrigger = now;
            onDetected();
          }
        }
      }
      _previousFrame = gray;
    } catch (_) {
      // Frame capture failed on this tick — skip and try again next interval.
    } finally {
      _busy = false;
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _previousFrame = null;
  }
}
