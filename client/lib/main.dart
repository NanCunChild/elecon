import 'package:flutter/material.dart';

void main() {
  runApp(const EleconApp());
}

class EleconApp extends StatelessWidget {
  const EleconApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'elecon',
      theme: ThemeData(useMaterial3: true),
      home: const Scaffold(
        body: Center(child: Text('elecon — skeleton')),
      ),
    );
  }
}
