import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import 'signaling.dart';

/// Thrown when the access-code handshake fails, either because a peer
/// supplied the wrong code or because the exchange timed out.
class AuthFailedException implements Exception {
  final String message;
  AuthFailedException(this.message);
  @override
  String toString() => 'AuthFailedException: $message';
}

/// Wraps a [SignalingSocket] with a mutual, access-code-based handshake and
/// AES-256-GCM encryption for every message exchanged afterwards.
///
/// This exists so that a device merely sitting on the same Wi-Fi/LAN cannot
/// connect to the server's signaling port, complete the WebRTC handshake,
/// and watch the stream: it must first prove it knows the shared access
/// code, and every SDP/ICE message on the wire is encrypted rather than
/// sent as plain JSON. The actual media (once the connection is set up) is
/// already protected end-to-end by WebRTC's mandatory DTLS-SRTP, so gating
/// who is allowed to complete that setup is what actually keeps other
/// people on the network from seeing the image.
class SecureSignaling {
  final SignalingSocket raw;
  late final SecretKey _key;
  final _aesGcm = AesGcm.with256bits();
  final _pbkdf2 = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 100000, bits: 256);
  final _random = Random.secure();

  SecureSignaling(this.raw);

  List<int> _randomBytes(int n) => List<int>.generate(n, (_) => _random.nextInt(256));

  bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// Server side of the handshake. Sends a random salt + nonce, waits for
  /// the client to prove it knows [accessCode] against that nonce, then
  /// proves the server side knows it too (mutual authentication).
  Future<void> authenticateAsServer(String accessCode) async {
    final salt = _randomBytes(16);
    final serverNonce = _randomBytes(16);
    _key = await _pbkdf2.deriveKeyFromPassword(password: accessCode, nonce: salt);

    raw.send({
      'type': 'hello',
      'salt': base64Encode(salt),
      'serverNonce': base64Encode(serverNonce),
    });

    final authMsg = await raw.messages
        .firstWhere((m) => m['type'] == 'auth')
        .timeout(const Duration(seconds: 10),
            onTimeout: () => throw AuthFailedException('Client did not respond to the challenge'));

    final clientProof = base64Decode(authMsg['proof'] as String);
    final clientNonce = base64Decode(authMsg['clientNonce'] as String);

    final expectedProof = await Hmac.sha256().calculateMac(serverNonce, secretKey: _key);
    if (!_constantTimeEquals(expectedProof.bytes, clientProof)) {
      raw.send({'type': 'authResult', 'ok': false});
      throw AuthFailedException('Client supplied the wrong access code');
    }

    final serverProof = await Hmac.sha256().calculateMac(clientNonce, secretKey: _key);
    raw.send({'type': 'authResult', 'ok': true, 'proof': base64Encode(serverProof.bytes)});
  }

  /// Client side of the handshake: waits for the server's salt/nonce,
  /// proves knowledge of [accessCode] without ever sending the code itself,
  /// and checks the server's counter-proof so a rogue "server" on the
  /// network can't fool the client either.
  Future<void> authenticateAsClient(String accessCode) async {
    final hello = await raw.messages
        .firstWhere((m) => m['type'] == 'hello')
        .timeout(const Duration(seconds: 10),
            onTimeout: () => throw AuthFailedException('No response from server'));

    final salt = base64Decode(hello['salt'] as String);
    final serverNonce = base64Decode(hello['serverNonce'] as String);
    _key = await _pbkdf2.deriveKeyFromPassword(password: accessCode, nonce: salt);

    final clientNonce = _randomBytes(16);
    final proof = await Hmac.sha256().calculateMac(serverNonce, secretKey: _key);

    raw.send({
      'type': 'auth',
      'proof': base64Encode(proof.bytes),
      'clientNonce': base64Encode(clientNonce),
    });

    final result = await raw.messages
        .firstWhere((m) => m['type'] == 'authResult')
        .timeout(const Duration(seconds: 10),
            onTimeout: () => throw AuthFailedException('No auth result from server'));

    if (result['ok'] != true) {
      throw AuthFailedException('Access code was rejected by the server');
    }

    final serverProof = base64Decode(result['proof'] as String);
    final expected = await Hmac.sha256().calculateMac(clientNonce, secretKey: _key);
    if (!_constantTimeEquals(expected.bytes, serverProof)) {
      throw AuthFailedException('Could not verify server identity');
    }
  }

  /// Encrypts [msg] with AES-256-GCM under the session key and sends it.
  Future<void> sendSecure(Map<String, dynamic> msg) async {
    final nonce = _randomBytes(12);
    final plainBytes = utf8.encode(jsonEncode(msg));
    final box = await _aesGcm.encrypt(plainBytes, secretKey: _key, nonce: nonce);
    raw.send({
      'type': 'enc',
      'nonce': base64Encode(box.nonce),
      'cipherText': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    });
  }

  /// Stream of decrypted, authenticated messages from the peer. Anything
  /// that fails to decrypt/authenticate (e.g. tampered or forged packets)
  /// is silently dropped rather than surfaced, since it cannot be trusted.
  Stream<Map<String, dynamic>> get secureMessages async* {
    await for (final m in raw.messages) {
      if (m['type'] != 'enc') continue;
      try {
        final nonce = base64Decode(m['nonce'] as String);
        final cipherText = base64Decode(m['cipherText'] as String);
        final mac = base64Decode(m['mac'] as String);
        final clear = await _aesGcm.decrypt(
          SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
          secretKey: _key,
        );
        yield jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
      } catch (_) {
        // Drop anything that doesn't decrypt/authenticate cleanly.
      }
    }
  }
}

/// Generates a random human-friendly access code, e.g. "482913".
String generateAccessCode() {
  final rand = Random.secure();
  final code = 100000 + rand.nextInt(900000);
  return code.toString();
}
