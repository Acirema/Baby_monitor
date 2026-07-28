// Copyright (c) 2026 Your Company/Name.
// Licensed under the MIT License — see LICENSE for details.

import 'dart:async';
import 'package:noise_meter/noise_meter.dart';

/// Listens to the microphone's decibel level and fires [onDetected]
/// whenever the mean decibel level crosses [thresholdDb], respecting a
/// [cooldown] so a single loud event doesn't spam multiple alerts.
class SoundDetector {
  final double thresholdDb;
  final Duration cooldown;
  final void Function() onDetected;
  final void Function(double currentDb)? onLevel;

  NoiseMeter? _noiseMeter;
  StreamSubscription<NoiseReading>? _sub;
  DateTime _lastTrigger = DateTime.fromMillisecondsSinceEpoch(0);

  SoundDetector({
    required this.onDetected,
    this.onLevel,
    this.thresholdDb = 70.0,
    this.cooldown = const Duration(seconds: 2),
  });

  void start() {
    _noiseMeter = NoiseMeter();
    _sub = _noiseMeter!.noise.listen(_onReading, onError: (_) {});
  }

  void _onReading(NoiseReading reading) {
    final db = reading.meanDecibel;
    onLevel?.call(db);
    if (db.isFinite && db >= thresholdDb) {
      final now = DateTime.now();
      if (now.difference(_lastTrigger) > cooldown) {
        _lastTrigger = now;
        onDetected();
      }
    }
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _noiseMeter = null;
  }
}
