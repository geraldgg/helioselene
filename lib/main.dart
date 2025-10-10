import 'package:flutter/material.dart';
import 'screens/home_page.dart';
import 'package:logging/logging.dart';
import 'core/ffi.dart';
import 'models/satellite.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    // ignore: avoid_print
    print('${record.level.name}: ${record.time}: ${record.loggerName}: ${record.message}');
  });

  // Warm TLE cache (non-blocking for UI after brief await to avoid jank)
  try {
    await NativeCore.prefetchTles(Satellite.supportedSatellites);
  } catch (e) {
    // ignore: avoid_print
    print('Prefetch TLE failed: $e');
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HelioSelene',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
