import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'screens/studio_screen.dart';

void main() {
  runApp(const ProviderScope(child: BroadcastMyRadioApp()));
}

class BroadcastMyRadioApp extends StatelessWidget {
  const BroadcastMyRadioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Broadcast My Radio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0),
          brightness: Brightness.dark,
        ),
      ),
      home: const StudioScreen(),
    );
  }
}
