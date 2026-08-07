import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'theme/broadcastng_theme.dart';
import 'screens/studio_screen.dart';

void main() {
  runApp(const ProviderScope(child: BroadcastNGApp()));
}

class BroadcastNGApp extends StatelessWidget {
  const BroadcastNGApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BroadcastNG',
      debugShowCheckedModeBanner: false,
      theme: BroadcastNGTheme.theme,
      home: const StudioScreen(),
    );
  }
}
