// Copyright (c) 2026 Your Company/Name.
// Licensed under the MIT License — see LICENSE for details.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/detection_event.dart';
import '../services/motion_detector.dart';
import '../services/secure_channel.dart';
import '../services/signaling.dart';
import '../services/sound_detector.dart';
import '../services/webrtc_service.dart';

/// Everything associated with one connected viewer: its raw + encrypted
/// signaling channel, its own RTCPeerConnection (WebRTC here is a mesh —
/// each client gets a direct connection to the server, all fed from the
/// same local camera/mic tracks), and its own events data channel.
class _ClientSession {
  final String id;
  final Socket socket;
  final SignalingSocket signaling;
  final SecureSignaling secure;
  final RTCPeerConnection pc;
  RTCDataChannel? eventsChannel;
  StreamSubscription? _msgSub;
  String label;

  _ClientSession({
    required this.id,
    required this.socket,
    required this.signaling,
    required this.secure,
    required this.pc,
    required this.label,
  });

  Future<void> dispose() async {
    await _msgSub?.cancel();
    await eventsChannel?.close();
    await pc.close();
    signaling.dispose();
  }
}

class ServerScreen extends StatefulWidget {
  const ServerScreen({super.key});

  @override
  State<ServerScreen> createState() => _ServerScreenState();
}

class _ServerScreenState extends State<ServerScreen> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final _accessCodeController = TextEditingController(text: generateAccessCode());

  ServerSocket? _serverSocket;
  MediaStream? _localStream;
  final Map<String, _ClientSession> _sessions = {};
  int _sessionCounter = 0;

  SoundDetector? _soundDetector;
  MotionDetector? _motionDetector;

  String _status = 'Idle';
  String? _localIp;
  bool _motionEnabled = false;
  double _soundThreshold = 70;
  double _motionSensitivity = 0.03;
  double? _currentDb;
  final List<DetectionEvent> _log = [];

  bool get _serverRunning => _localStream != null;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _localRenderer.initialize();
    await _requestPermissions();
    _localIp = await NetworkInfo().getWifiIP();
    setState(() {});
  }

  Future<void> _requestPermissions() async {
    await [Permission.camera, Permission.microphone].request();
  }

  Future<void> _startServer() async {
    setState(() => _status = 'Starting camera & microphone...');
    try {
      _localStream = await WebRTCService.getLocalMedia();
      _localRenderer.srcObject = _localStream;
    } catch (e) {
      setState(() => _status = 'Failed to access camera/mic: $e');
      return;
    }

    try {
      _serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, defaultSignalingPort);
    } catch (e) {
      setState(() => _status = 'Failed to open port $defaultSignalingPort: $e');
      return;
    }

    // Detection runs once for the whole server, independent of how many
    // clients are watching, and fans out alerts to every connected client.
    _startDetectors();

    setState(() => _status =
        'Listening on $_localIp:$defaultSignalingPort  •  Access code: ${_accessCodeController.text}');

    _serverSocket!.listen((client) => _onClientConnected(client));
  }

  Future<void> _onClientConnected(Socket clientSocket) async {
    final id = 'client-${++_sessionCounter}';
    final remote = '${clientSocket.remoteAddress.address}:${clientSocket.remotePort}';
    setState(() => _status = 'Device connecting ($remote), verifying access code...');

    final rawSignaling = SignalingSocket(clientSocket);
    final secure = SecureSignaling(rawSignaling);

    try {
      await secure.authenticateAsServer(_accessCodeController.text.trim());
    } catch (e) {
      setState(() => _status = 'Rejected an unauthorized connection attempt from $remote ($e).');
      rawSignaling.dispose();
      return;
    }

    final pc = await WebRTCService.createConnection();
    for (final track in _localStream!.getTracks()) {
      await pc.addTrack(track, _localStream!);
    }

    final session = _ClientSession(
      id: id,
      socket: clientSocket,
      signaling: rawSignaling,
      secure: secure,
      pc: pc,
      label: remote,
    );
    _sessions[id] = session;

    final eventsChannel = await pc.createDataChannel('events', RTCDataChannelInit()..ordered = true);
    session.eventsChannel = eventsChannel;
    eventsChannel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen && mounted) {
        setState(() => _status = '${_sessions.length} client(s) connected. Streaming (encrypted).');
      }
    };

    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      secure.sendSecure({
        'type': 'ice',
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    pc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _removeSession(id);
      }
    };

    session._msgSub = secure.secureMessages.listen((msg) => _handleSignalingMessage(session, msg));

    clientSocket.done.then((_) => _removeSession(id)).catchError((_) => _removeSession(id));

    final offer = await pc.createOffer(WebRTCService.sdpConstraints);
    await pc.setLocalDescription(offer);
    secure.sendSecure({'type': 'offer', 'sdp': offer.sdp});

    setState(() => _status = '${_sessions.length} client(s) connected.');
  }

  Future<void> _handleSignalingMessage(_ClientSession session, Map<String, dynamic> msg) async {
    switch (msg['type']) {
      case 'answer':
        await session.pc.setRemoteDescription(RTCSessionDescription(msg['sdp'], 'answer'));
        break;
      case 'ice':
        await session.pc.addCandidate(RTCIceCandidate(
          msg['candidate'],
          msg['sdpMid'],
          msg['sdpMLineIndex'],
        ));
        break;
    }
  }

  void _removeSession(String id) {
    final session = _sessions.remove(id);
    session?.dispose();
    if (mounted) {
      setState(() => _status = _serverRunning
          ? '${_sessions.length} client(s) connected. Waiting for more on $_localIp:$defaultSignalingPort'
          : 'Stopped');
    }
  }

  void _startDetectors() {
    _soundDetector = SoundDetector(
      thresholdDb: _soundThreshold,
      onLevel: (db) {
        if (mounted) setState(() => _currentDb = db);
      },
      onDetected: () => _broadcastDetection(DetectionType.sound),
    )..start();

    if (_motionEnabled) _startMotionDetector();
  }

  void _startMotionDetector() {
    if (_localStream == null) return;
    final videoTracks = _localStream!.getVideoTracks();
    if (videoTracks.isEmpty) return;
    _motionDetector = MotionDetector(
      videoTrack: videoTracks.first,
      sensitivity: _motionSensitivity,
      onDetected: () => _broadcastDetection(DetectionType.motion),
    )..start();
  }

  void _broadcastDetection(DetectionType type) {
    final event = DetectionEvent(type);
    setState(() {
      _log.insert(0, event);
      if (_log.length > 30) _log.removeLast();
    });
    final payload = RTCDataChannelMessage(jsonEncode(event.toJson()));
    for (final session in _sessions.values) {
      final channel = session.eventsChannel;
      if (channel != null && channel.state == RTCDataChannelState.RTCDataChannelOpen) {
        channel.send(payload);
      }
    }
  }

  void _toggleMotion(bool enabled) {
    setState(() => _motionEnabled = enabled);
    if (enabled && _serverRunning) {
      _startMotionDetector();
    } else {
      _motionDetector?.stop();
      _motionDetector = null;
    }
  }

  void _regenerateAccessCode() {
    if (_serverRunning) return; // don't change it mid-session
    setState(() => _accessCodeController.text = generateAccessCode());
  }

  Future<void> _disconnectClient(String id) async {
    _removeSession(id);
  }

  Future<void> _stopServer() async {
    _soundDetector?.stop();
    _motionDetector?.stop();
    for (final session in _sessions.values.toList()) {
      await session.dispose();
    }
    _sessions.clear();
    await _serverSocket?.close();
    _serverSocket = null;
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream = null;
    setState(() => _status = 'Stopped');
  }

  @override
  void dispose() {
    _stopServer();
    _localRenderer.dispose();
    _accessCodeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Server')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Container(
                color: Colors.black,
                child: RTCVideoView(_localRenderer, mirror: false),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(_status, style: const TextStyle(fontWeight: FontWeight.bold)),
          if (_currentDb != null) Text('Mic level: ${_currentDb!.toStringAsFixed(1)} dB'),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Access code', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  const Text(
                    'Every client must enter this same code to connect. '
                    'Share it out-of-band — never post it publicly.',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _accessCodeController,
                          enabled: !_serverRunning,
                          decoration: const InputDecoration(
                            labelText: 'Access code',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Generate a new code',
                        icon: const Icon(Icons.refresh),
                        onPressed: !_serverRunning ? _regenerateAccessCode : null,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start Server'),
                  onPressed: !_serverRunning ? _startServer : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                  onPressed: !_serverRunning ? null : _stopServer,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Detection settings', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text('Sound threshold: ${_soundThreshold.toStringAsFixed(0)} dB'),
                  Slider(
                    min: 40,
                    max: 100,
                    value: _soundThreshold,
                    onChanged: (v) {
                      setState(() => _soundThreshold = v);
                      _soundDetector?.stop();
                      if (_serverRunning) {
                        _soundDetector = SoundDetector(
                          thresholdDb: _soundThreshold,
                          onLevel: (db) {
                            if (mounted) setState(() => _currentDb = db);
                          },
                          onDetected: () => _broadcastDetection(DetectionType.sound),
                        )..start();
                      }
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Enable motion detection'),
                    value: _motionEnabled,
                    onChanged: _toggleMotion,
                  ),
                  if (_motionEnabled) ...[
                    Text('Motion sensitivity: ${(_motionSensitivity * 100).toStringAsFixed(1)}%'
                        ' of frame changed'),
                    Slider(
                      min: 0.01,
                      max: 0.15,
                      value: _motionSensitivity,
                      onChanged: (v) {
                        setState(() => _motionSensitivity = v);
                        _motionDetector?.stop();
                        if (_serverRunning) _startMotionDetector();
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Connected clients (${_sessions.length})',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  if (_sessions.isEmpty)
                    const Text('No clients connected yet.', style: TextStyle(color: Colors.white70)),
                  ..._sessions.values.map((s) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        leading: const Icon(Icons.person),
                        title: Text(s.label),
                        trailing: IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: 'Disconnect this client',
                          onPressed: () => _disconnectClient(s.id),
                        ),
                      )),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_log.isNotEmpty) ...[
            const Text('Recent events', style: TextStyle(fontWeight: FontWeight.bold)),
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
