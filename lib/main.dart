// Copyright (c) 2026 Your Company/Name.
// Licensed under the MIT License — see LICENSE for details.

import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const MonitorApp());
}

class MonitorApp extends StatelessWidget {
  const MonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Video Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const HomeScreen(),
    );
  }
}
