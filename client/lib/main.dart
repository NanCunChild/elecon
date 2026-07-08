import 'package:flutter/material.dart';

import 'ui/home/home_page.dart';

void main() {
  runApp(const EleconApp());
}

class EleconApp extends StatelessWidget {
  const EleconApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'elecon',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff3867d6)),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff7da6ff),
          brightness: Brightness.dark,
        ),
      ),
      home: const EleconHomePage(),
    );
  }
}
