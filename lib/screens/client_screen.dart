// Licensed under the MIT License — see LICENSE for details.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:floating/floating.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/detection_event.dart';
import '../services/keep_alive_service.dart';
import '../services/secure_channel.dart';
import '../services/signaling.dart';
import '../services/webrtc_service.dart';
import '../widgets/alert_popup.dart';
import '../widgets/fullscreen_video.dart';

/// If the connection drops unexpectedly, keep retrying for this long before
/// giving up and surfacing "disconnected" to the user.
const Duration kReconnectGiveUpTimeout = Duration(minutes: 5);
const Duration kReconnectRetryInterval = Duration(seconds: 5);
const String kLastIpPrefKey = 'video_monitor_last_server_ip';

class ClientScreen extends StatefulWidget {
  const ClientScreen({super.key});

  @override
  State<ClientScreen> createState() => _ClientScreenState();
}

class _ClientScreenState extends State<ClientScreen> {
  final _ipController = TextEditingController();
  final _accessCodeController = TextEditingController();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  final Floating _floating = Floating();

  Socket? _socket;
  SignalingSocket? _rawSignaling;
  SecureSignaling? _secureSignaling;
  StreamSubscription? _secureSub;
  RTCPeerConnection? _pc;
  RTCDataChannel? _eventsChannel;

  String _status = 'Not connected';
  bool _connecting = false;
  bool _connected = false;
  bool _stayActive = false;
  bool _manualDisconnect = true;
  bool _autoRetrying = false;
  Timer? _reconnectTimer;
  DateTime? _reconnectDeadline;
  final List<DetectionEvent> _log = [];

  @override
  void initState() {
    super.initState();
    _remoteRenderer.initialize();
    _loadLastIp();
  }

  Future<void> _loadLastIp() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(kLastIpPrefKey);
    if (saved != null && mounted) {
      setState(() => _ipController.text = saved);
    }
  }

  Future<void> _connect({bool isReconnect = false}) async {
    final ip = _ipController.text.trim();
    final code = _accessCodeController.text.trim();
    if (ip.isEmpty || code.isEmpty) {
      setState(() => _status = 'Enter both the server IP and the access code.');
      return;
    }

    if (!isReconnect) {
      _manualDisconnect = false;
      _reconnectDeadline = null;
      _autoRetrying = false;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      setState(() => _connecting = true);
    }
    setState(() => _status = isReconnect
        ? 'Reconnecting to $ip:$defaultSignalingPort ...'
        : 'Connecting to $ip:$defaultSignalingPort ...');

    try {
      _socket = await Socket.connect(ip, defaultSignalingPort, timeout: const Duration(seconds: 8));
    } catch (e) {
      if (!isReconnect) setState(() => _connecting = false);
      _scheduleReconnectOrGiveUp('Could not connect: $e');
      return;
    }

    _rawSignaling = SignalingSocket(_socket!);
    final secure = SecureSignaling(_rawSignaling!);

    setState(() => _status = 'Verifying access code...');
    try {
      await secure.authenticateAsClient(code);
    } catch (e) {
      if (!isReconnect) setState(() => _connecting = false);
      _rawSignaling!.dispose();
      _rawSignaling = null;
      // A wrong/rejected access code won't fix itself by retrying, so treat
      // it as final rather than entering the retry loop.
      setState(() {
        _status = 'Access denied: $e';
        _connected = false;
        _autoRetrying = false;
      });
      return;
    }

    // Credentials work — remember this IP so it doesn't need retyping, and
    // reset the reconnect countdown now that we're actually back online.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kLastIpPrefKey, ip);
    _reconnectDeadline = null;

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

    _pc!.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _handleUnexpectedDisconnect();
      }
    };

    _secureSub = _secureSignaling!.secureMessages.listen(_handleSignalingMessage);

    _socket!.done.then((_) => _handleUnexpectedDisconnect()).catchError((_) => _handleUnexpectedDisconnect());

    setState(() {
      _connecting = false;
      _connected = true;
      _autoRetrying = false;
      _status = 'Access code verified. Negotiating stream...';
    });

    await WakelockPlus.enable();
    if (_stayActive) {
      await KeepAliveService.start(
        title: 'Video Monitor — Connected',
        text: 'Watching the stream from $ip in the background',
      );
    }
    await _updatePiPEnablement();
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

  /// Called when the socket or the WebRTC connection drops without the user
  /// having pressed Disconnect. Tears down the dead connection and retries
  /// every few seconds for up to [kReconnectGiveUpTimeout] before giving up.
  Future<void> _handleUnexpectedDisconnect() async {
    if (_manualDisconnect || !mounted) return;
    if (_reconnectTimer != null) return; // already retrying, don't double-schedule

    await _teardownConnection();

    _reconnectDeadline ??= DateTime.now().add(kReconnectGiveUpTimeout);
    if (DateTime.now().isAfter(_reconnectDeadline!)) {
      _reconnectDeadline = null;
      await WakelockPlus.disable();
      await KeepAliveService.stop();
      if (mounted) {
        setState(() {
          _connected = false;
          _autoRetrying = false;
          _status = 'Lost connection and could not reconnect within 5 minutes.';
        });
      }
      await _updatePiPEnablement();
      return;
    }

    final remaining = _reconnectDeadline!.difference(DateTime.now());
    if (mounted) {
      setState(() {
        _connected = false;
        _autoRetrying = true;
        _status = 'Connection lost — retrying (giving up in ${remaining.inMinutes + 1} min)...';
      });
    }
    _reconnectTimer = Timer(kReconnectRetryInterval, () {
      _reconnectTimer = null;
      _connect(isReconnect: true);
    });
  }

  void _scheduleReconnectOrGiveUp(String failureStatus) {
    if (_manualDisconnect) return;
    setState(() => _status = failureStatus);
    _handleUnexpectedDisconnect();
  }

  /// Closes the current socket/peer connection resources without touching
  /// the manual-disconnect flag or UI text fields, so a retry can reuse them.
  Future<void> _teardownConnection() async {
    await _secureSub?.cancel();
    _secureSub = null;
    _secureSignaling = null;
    await _eventsChannel?.close();
    _eventsChannel = null;
    await _pc?.close();
    _pc = null;
    _rawSignaling?.dispose();
    _rawSignaling = null;
    _socket?.destroy();
    _socket = null;
  }

  /// Keeps the Android Picture-in-Picture auto-trigger in sync with whether
  /// the user wants to "stay active" and whether we're actually connected.
  /// When both are true, minimizing the app (home button / app switch) will
  /// shrink it into a small corner window showing just the video — see
  /// [_buildPiPView]. No-op on non-Android platforms.
  Future<void> _updatePiPEnablement() async {
    if (!Platform.isAndroid) return;
    if (_stayActive && _connected) {
      final available = await _floating.isPipAvailable;
      if (available) {
        await _floating.enable(const OnLeavePiP());
      }
    } else {
      await _floating.cancelOnLeavePiP();
    }
  }

  Future<void> _onStayActiveToggled(bool value) async {
    setState(() => _stayActive = value);
    if (value && _connected) {
      await KeepAliveService.start(
        title: 'Video Monitor — Connected',
        text: 'Watching the stream in the background',
      );
    } else if (!value) {
      await KeepAliveService.stop();
    }
    await _updatePiPEnablement();
  }

  Future<void> _disconnect() async {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectDeadline = null;
    await _teardownConnection();
    await KeepAliveService.stop();
    await WakelockPlus.disable();
    setState(() {
      _connected = false;
      _autoRetrying = false;
      _status = 'Disconnected';
      _remoteRenderer.srcObject = null;
    });
    await _updatePiPEnablement();
  }

  Future<void> _openFullscreen() {
    return showFullscreenVideo(context, renderer: _remoteRenderer, label: 'Live stream');
  }

  /// What's shown inside the small Android PiP corner window: just the
  /// video, no app bar, no buttons, no text — exactly what was asked for.
  Widget _buildPiPView() {
    return Container(
      color: Colors.black,
      child: RTCVideoView(_remoteRenderer),
    );
  }

  @override
  void dispose() {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _teardownConnection();
    WakelockPlus.disable();
    if (Platform.isAndroid) _floating.cancelOnLeavePiP();
    _remoteRenderer.dispose();
    _ipController.dispose();
    _accessCodeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PiPSwitcher(
      childWhenDisabled: _buildFullUI(context),
      childWhenEnabled: _buildPiPView(),
    );
  }

  Widget _buildFullUI(BuildContext context) {
    final showFields = !_connected && !_autoRetrying;
    return Scaffold(
      appBar: AppBar(title: const Text('Client')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    color: Colors.black,
                    child: RTCVideoView(_remoteRenderer),
                  ),
                  if (_connected)
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: IconButton.filledTonal(
                        icon: const Icon(Icons.fullscreen),
                        tooltip: 'Fullscreen',
                        onPressed: _openFullscreen,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(_status, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          if (showFields) ...[
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
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Stay active over other apps'),
              subtitle: const Text(
                'Keeps the screen on, the connection alive, and shows a small '
                'video-only corner window when you switch apps (Android only).',
                style: TextStyle(fontSize: 12),
              ),
              value: _stayActive,
              onChanged: _onStayActiveToggled,
            ),
            const SizedBox(height: 8),
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
          ] else ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Stay active over other apps'),
              subtitle: const Text(
                'Keeps the screen on, the connection alive, and shows a small '
                'video-only corner window when you switch apps (Android only).',
                style: TextStyle(fontSize: 12),
              ),
              value: _stayActive,
              onChanged: _onStayActiveToggled,
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.link_off),
                label: Text(_autoRetrying ? 'Stop retrying' : 'Disconnect'),
                onPressed: _disconnect,
              ),
            ),
          ],
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
