// Copyright (c) 2026 Your Company/Name.
// Licensed under the MIT License — see LICENSE for details.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/detection_event.dart';
import '../services/secure_channel.dart';
import '../services/signaling.dart';
import '../services/webrtc_service.dart';
import '../widgets/alert_popup.dart';

class ClientScreen extends StatefulWidget {
  const ClientScreen({super.key});

  @override
  State<ClientScreen> createState() => _ClientScreenState();
}

class _ClientScreenState extends State<ClientScreen> {
  final _ipController = TextEditingController();
  final _accessCodeController = TextEditingController();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  Socket? _socket;
  SignalingSocket? _rawSignaling;
  SecureSignaling? _secureSignaling;
  StreamSubscription? _secureSub;
  RTCPeerConnection? _pc;
  RTCDataChannel? _eventsChannel;

  String _status = 'Not connected';
  bool _connecting = false;
  bool _connected = false;
  final List<DetectionEvent> _log = [];

  @override
  void initState() {
    super.initState();
    _remoteRenderer.initialize();
    Permission.microphone.request(); // for playback audio focus on some platforms
  }

  Future<void> _connect() async {
    final ip = _ipController.text.trim();
    final code = _accessCodeController.text.trim();
    if (ip.isEmpty || code.isEmpty) {
      setState(() => _status = 'Enter both the server IP and the access code.');
      return;
    }

    setState(() {
      _connecting = true;
      _status = 'Connecting to $ip:$defaultSignalingPort ...';
    });

    try {
      _socket = await Socket.connect(ip, defaultSignalingPort, timeout: const Duration(seconds: 8));
    } catch (e) {
      setState(() {
        _connecting = false;
        _status = 'Could not connect: $e';
      });
      return;
    }

    _rawSignaling = SignalingSocket(_socket!);
    final secure = SecureSignaling(_rawSignaling!);

    setState(() => _status = 'Verifying access code...');
    try {
      await secure.authenticateAsClient(code);
    } catch (e) {
      setState(() {
        _connecting = false;
        _status = 'Access denied: $e';
      });
      _rawSignaling!.dispose();
      _rawSignaling = null;
      return;
    }

    _secureSignaling = secure;

    _pc = await WebRTCService.createConnection();

    _pc!.onTrack = (event) {
      if (event.track.kind == 'video' || event.streams.isNotEmpty) {
        setState(() {
          _remoteRenderer.srcObject = event.streams.isNotEmpty ? event.streams[0] : null;
        });
      }
    };

    _pc!.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      _secureSignaling!.sendSecure({
        'type': 'ice',
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    _pc!.onDataChannel = (channel) {
      _eventsChannel = channel;
      channel.onMessage = (RTCDataChannelMessage message) {
        if (message.isBinary) return;
        try {
          final json = jsonDecode(message.text) as Map<String, dynamic>;
          final event = DetectionEvent.fromJson(json);
          if (event != null) _onDetectionReceived(event);
        } catch (_) {}
      };
    };

    _secureSub = _secureSignaling!.secureMessages.listen(_handleSignalingMessage);

    setState(() {
      _connecting = false;
      _connected = true;
      _status = 'Access code verified. Negotiating stream...';
    });
  }

  Future<void> _handleSignalingMessage(Map<String, dynamic> msg) async {
    switch (msg['type']) {
      case 'offer':
        await _pc!.setRemoteDescription(RTCSessionDescription(msg['sdp'], 'offer'));
        final answer = await _pc!.createAnswer(WebRTCService.sdpConstraints);
        await _pc!.setLocalDescription(answer);
        _secureSignaling!.sendSecure({'type': 'answer', 'sdp': answer.sdp});
        setState(() => _status = 'Connected. Receiving encrypted stream.');
        break;
      case 'ice':
        await _pc!.addCandidate(RTCIceCandidate(
          msg['candidate'],
          msg['sdpMid'],
          msg['sdpMLineIndex'],
        ));
        break;
    }
  }

  void _onDetectionReceived(DetectionEvent event) {
    setState(() {
      _log.insert(0, event);
      if (_log.length > 30) _log.removeLast();
    });
    showDetectionPopup(context, event);
  }

  Future<void> _disconnect() async {
    await _secureSub?.cancel();
    _secureSub = null;
    _secureSignaling = null;
    await _eventsChannel?.close();
    await _pc?.close();
    _rawSignaling?.dispose();
    _rawSignaling = null;
    _socket?.destroy();
    _socket = null;
    setState(() {
      _connected = false;
      _status = 'Disconnected';
      _remoteRenderer.srcObject = null;
    });
  }

  @override
  void dispose() {
    _disconnect();
    _remoteRenderer.dispose();
    _ipController.dispose();
    _accessCodeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Client')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Container(
                color: Colors.black,
                child: RTCVideoView(_remoteRenderer),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(_status, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          if (!_connected) ...[
            TextField(
              controller: _ipController,
              decoration: const InputDecoration(
                labelText: 'Server IP address',
                hintText: 'e.g. 192.168.1.42',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _accessCodeController,
              decoration: const InputDecoration(
                labelText: 'Access code',
                hintText: 'Shown on the server screen',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              obscureText: true,
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                onPressed: _connecting ? null : _connect,
                child: _connecting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Connect'),
              ),
            ),
          ] else
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.link_off),
                label: const Text('Disconnect'),
                onPressed: _disconnect,
              ),
            ),
          const SizedBox(height: 24),
          if (_log.isNotEmpty) ...[
            const Text('Recent alerts', style: TextStyle(fontWeight: FontWeight.bold)),
            ..._log.map((e) => ListTile(
                  dense: true,
                  leading: Icon(e.type == DetectionType.sound ? Icons.volume_up : Icons.directions_run),
                  title: Text(e.label),
                  subtitle: Text(e.time.toLocal().toString()),
                )),
          ],
        ],
      ),
    );
  }
}
