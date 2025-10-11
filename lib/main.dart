import 'dart:async';
import 'package:http/http.dart' show ClientException;
import 'package:flutter/material.dart';
import 'screens/home_page.dart';
import 'package:logging/logging.dart';
import 'core/ffi.dart';
import 'core/shared_tile_provider.dart';
import 'models/satellite.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (FlutterErrorDetails details) {
    final ex = details.exception;
    final msg = ex.toString();
    if (ex is ClientException && (msg.contains('Client is already closed') || msg.contains('Connection attempt cancelled'))) {
      return; // suppress benign tile cancellation noise
    }
    FlutterError.presentError(details);
  };

  runZonedGuarded(() async {
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((record) {
      // ignore: avoid_print
      print('${record.level.name}: ${record.time}: ${record.loggerName}: ${record.message}');
    });

    // Initialize custom disk tile cache (non-blocking if already initialized)
    try {
      await SharedTileProvider.init();
    } catch (e) {
      // ignore: avoid_print
      print('Tile provider init failed (fallback to network only): $e');
    }

    // Warm TLE cache
    try {
      await NativeCore.prefetchTles(Satellite.supportedSatellites);
    } catch (e) {
      // ignore: avoid_print
      print('Prefetch TLE failed: $e');
    }

    // Run initial prediction (best-effort; uses placeholder coordinates for now)
    try {
      final results = await NativeCore.predictTransitsForSatellites(
        satellites: Satellite.supportedSatellites,
        lat: 0.0,
        lon: 0.0,
        altM: 0.0,
        startUtc: DateTime.now(),
        endUtc: DateTime.now().add(const Duration(days: 15)),
      );
      // ignore: avoid_print
      print('Startup prediction results count: ${results.length}');
    } catch (e) {
      // ignore: avoid_print
      print('Prediction at startup failed: $e');
    }

    runApp(const MyApp());
  }, (error, stack) {
    final msg = error.toString();
    if (error is ClientException && (msg.contains('Client is already closed') || msg.contains('Connection attempt cancelled'))) {
      return; // swallow benign tile cancellation
    }
    // ignore: avoid_print
    print('Uncaught zone error: $error\n$stack');
  });
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
