// Copyright (c) 2026 Your Company/Name.
// Licensed under the MIT License — see LICENSE for details.

import 'package:flutter/material.dart';
import '../models/detection_event.dart';

/// Shows a brief, auto-dismissing top banner for a detection event.
/// Safe to call repeatedly; each call stacks its own banner via the
/// nearest [ScaffoldMessenger].
void showDetectionPopup(BuildContext context, DetectionEvent event) {
  final messenger = ScaffoldMessenger.of(context);
  final isSound = event.type == DetectionType.sound;

  messenger.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: isSound ? Colors.orange.shade800 : Colors.red.shade800,
      duration: const Duration(seconds: 3),
      content: Row(
        children: [
          Icon(isSound ? Icons.volume_up : Icons.directions_run, color: Colors.white),
          const SizedBox(width: 12),
          Text(
            event.label,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    ),
  );
}
