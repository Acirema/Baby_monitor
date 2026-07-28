// Copyright (c) 2026 Your Company/Name.
// Licensed under the MIT License — see LICENSE for details.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Wraps a raw [Socket] and exchanges newline-delimited JSON messages.
/// Used to carry the WebRTC SDP offer/answer and ICE candidates between
/// the server and the client before the peer-to-peer connection takes over.
class SignalingSocket {
  final Socket socket;
  final _controller = StreamController<Map<String, dynamic>>.broadcast();
  String _buffer = '';

  SignalingSocket(this.socket) {
    socket.listen(_onData, onError: (_) => dispose(), onDone: dispose);
  }

  Stream<Map<String, dynamic>> get messages => _controller.stream;

  void send(Map<String, dynamic> msg) {
    try {
      socket.write('${jsonEncode(msg)}\n');
    } catch (_) {
      // socket may already be closed
    }
  }

  void _onData(Uint8List data) {
    _buffer += utf8.decode(data, allowMalformed: true);
    while (true) {
      final idx = _buffer.indexOf('\n');
      if (idx == -1) break;
      final line = _buffer.substring(0, idx).trim();
      _buffer = _buffer.substring(idx + 1);
      if (line.isEmpty) continue;
      try {
        _controller.add(jsonDecode(line) as Map<String, dynamic>);
      } catch (_) {
        // ignore malformed line
      }
    }
  }

  void dispose() {
    if (!_controller.isClosed) _controller.close();
    try {
      socket.destroy();
    } catch (_) {}
  }
}

const int defaultSignalingPort = 8888;
