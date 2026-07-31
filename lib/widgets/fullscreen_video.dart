// Copyright (c) 2026 Your Company/Name.
// Licensed under the MIT License — see LICENSE for details.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Pushes a black, chrome-free fullscreen route showing [renderer]. Hides
/// the system status/nav bars while open and restores them on exit. Tap
/// anywhere, or the close button, to leave fullscreen.
Future<void> showFullscreenVideo(
  BuildContext context, {
  required RTCVideoRenderer renderer,
  bool mirror = false,
  String? label,
}) async {
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await Navigator.of(context).push(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _FullscreenVideoPage(renderer: renderer, mirror: mirror, label: label),
    ),
  );
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
}

class _FullscreenVideoPage extends StatelessWidget {
  final RTCVideoRenderer renderer;
  final bool mirror;
  final String? label;

  const _FullscreenVideoPage({required this.renderer, required this.mirror, this.label});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: RTCVideoView(
                renderer,
                mirror: mirror,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: SafeArea(
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 28),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ),
            if (label != null)
              Positioned(
                top: 16,
                left: 16,
                child: SafeArea(
                  child: Text(
                    label!,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
