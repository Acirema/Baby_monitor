// Copyright (c) 2026 Your Company/Name.
// Licensed under the MIT License — see LICENSE for details.

import 'package:flutter/material.dart';
import 'server_screen.dart';
import 'client_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Video Monitor')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.videocam, size: 72),
                const SizedBox(height: 16),
                const Text('Choose a role', style: TextStyle(fontSize: 20)),
                const SizedBox(height: 8),
                const Text(
                  'Server captures camera/mic and streams to a client, '
                  'alerting it on sound (and optionally motion). '
                  'Client just watches and listens.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.dns),
                    label: const Text('Start as Server (broadcast)'),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const ServerScreen()),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.phone_android),
                    label: const Text('Connect as Client (viewer)'),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const ClientScreen()),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
