import 'dart:async';
import 'package:http/http.dart' show ClientException;
import 'package:flutter/material.dart';
import 'screens/home_page.dart';
import 'package:logging/logging.dart';
import 'core/ffi.dart';
import 'core/shared_tile_provider.dart';
import 'core/notification_service.dart';
import 'core/background_service.dart';
import 'models/satellite.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart';
import 'dart:convert';
import 'package:flutter/services.dart';

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

    // Initialize notifications (local scheduling service)
    try {
      await NotificationService.init();
    } catch (e) {
      // ignore: avoid_print
      print('Notification init failed: $e');
    }

    // Initialize background service for daily prediction refresh
    try {
      await BackgroundService.initialize();
    } catch (e) {
      // ignore: avoid_print
      print('Background service init failed: $e');
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
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('en', ''), // English
        Locale('fr', ''), // French
      ],
      home: const HomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  late Map<String, String> _localizedStrings;

  @override
  void initState() {
    super.initState();
    _loadLocalizedStrings();
  }

  Future<void> _loadLocalizedStrings() async {
    final locale = Localizations.localeOf(context);
    final jsonString = await rootBundle.loadString('assets/l10n/${locale.languageCode}.json');
    final Map<String, dynamic> jsonMap = json.decode(jsonString);
    setState(() {
      _localizedStrings = jsonMap.map((key, value) => MapEntry(key, value.toString()));
    });
  }

  String translate(String key) {
    return _localizedStrings[key] ?? key;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(translate('appTitle')),
      ),
      body: Center(
        child: Text(translate('welcomeMessage')),
      ),
    );
  }
}
