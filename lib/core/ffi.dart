import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';
import 'dart:io' show Platform;
import 'dart:convert';
import 'package:logging/logging.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart'; // added for TLE caching

import '../models/transit.dart';
import '../models/satellite.dart';

typedef _PredictTransitsNative = ffi.Pointer<ffi.Char> Function(
  ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, // tle1, tle2
  ffi.Double, ffi.Double, ffi.Double, // lat, lon, alt_m
  ffi.Int64, ffi.Int64,               // start_epoch, end_epoch (UTC seconds)
  ffi.Double                          // max_distance_km (was near_arcmin)
);

typedef _PredictTransitsDart = ffi.Pointer<ffi.Char> Function(
  ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>,
  double, double, double,
  int, int,
  double
);

typedef _FreeJsonNative = ffi.Void Function(ffi.Pointer<ffi.Char>);
typedef _FreeJsonDart = void Function(ffi.Pointer<ffi.Char>);

class NativeCore {
  static final Logger _logger = Logger('NativeCore');
  // Added telemetry counters for UI to detect TLE failures
  static int lastSatellitesAttempted = 0;
  static int lastSuccessfulTleFetches = 0;

  static ffi.DynamicLibrary _open() {
    if (Platform.isAndroid) {
      return ffi.DynamicLibrary.open('libisscore.so');
    } else if (Platform.isWindows) {
      return ffi.DynamicLibrary.open('isscore.dll');
    } else if (Platform.isLinux) {
      return ffi.DynamicLibrary.open('libisscore.so');
    } else if (Platform.isMacOS || Platform.isIOS) {
      return ffi.DynamicLibrary.process();
    }
    throw UnsupportedError('Unsupported platform');
  }

  static final ffi.DynamicLibrary _lib = _open();

  static final _predict = _lib
      .lookupFunction<_PredictTransitsNative, _PredictTransitsDart>('predict_transits');
  static final _freeJson = _lib
      .lookupFunction<_FreeJsonNative, _FreeJsonDart>('free_json');

  static List<Transit> predictTransits({
    required String tle1,
    required String tle2,
    required double lat,
    required double lon,
    required double altM,
    required DateTime startUtc,
    required DateTime endUtc,
    double nearMarginDeg = 0.5, // retained for API stability, ignored in v2
    double maxDistanceKm = 35.0,
  }) {
    final startEpoch = startUtc.toUtc().millisecondsSinceEpoch ~/ 1000;
    final endEpoch = endUtc.toUtc().millisecondsSinceEpoch ~/ 1000;
    _logger.info('[FFI] predictTransits (v2 only) called with:');
    _logger.info('  tle1: $tle1');
    _logger.info('  tle2: $tle2');
    _logger.info('  lat: $lat, lon: $lon, altM: $altM');
    _logger.info('  startEpoch: $startEpoch, endEpoch: $endEpoch');
    _logger.info('  nearMarginDeg (ignored in v2): $nearMarginDeg');
    _logger.info('  maxDistanceKm: $maxDistanceKm');

    final tle1Ptr = tle1.toNativeUtf8().cast<ffi.Char>();
    final tle2Ptr = tle2.toNativeUtf8().cast<ffi.Char>();
    try {
      final ptr = _predict(
        tle1Ptr, tle2Ptr,
        lat, lon, altM,
        startEpoch, endEpoch,
        maxDistanceKm,
      );
      if (ptr == ffi.nullptr) {
        _logger.severe('[FFI] native predict function returned null pointer');
        throw Exception('Native predict returned null');
      }
      final jsonStr = ptr.cast<Utf8>().toDartString();
      _logger.info('[FFI] Raw JSON from native: $jsonStr');
      _freeJson(ptr);
      final List<dynamic> decoded = json.decode(jsonStr);
      // Detect missing motion fields (likely stale native library not rebuilt with new struct)
      if (decoded.isNotEmpty && decoded.first is Map<String,dynamic>) {
        final m = decoded.first as Map<String,dynamic>;
        final missingDir = !m.containsKey('motion_direction_deg');
        final missingVelAlt = !m.containsKey('velocity_alt_deg_per_s');
        final missingVelAz = !m.containsKey('velocity_az_deg_per_s');
        if (missingDir || missingVelAlt || missingVelAz) {
          _logger.warning('[FFI] Motion/direction fields absent in native JSON. Rebuild the Rust library (isscore) to include velocity & direction fields.');
        }
      }
      return decoded.map((e) => Transit.fromJson(e)).toList();
    } catch (e, st) {
      _logger.severe('[FFI] Exception: $e\n$st');
      rethrow;
    } finally {
      malloc.free(tle1Ptr);
      malloc.free(tle2Ptr);
    }
  }

  /// Predict transits for multiple satellites (aggregated results)
  static Future<List<Transit>> predictTransitsForSatellites({
    required List<Satellite> satellites,
    required double lat,
    required double lon,
    required double altM,
    required DateTime startUtc,
    required DateTime endUtc,
    double nearMarginDeg = 0.5,
    double maxDistanceKm = 35.0,
  }) async {
    List<Transit> allResults = [];
    final selected = satellites.where((s) => s.selected).toList();
    lastSatellitesAttempted = selected.length;
    lastSuccessfulTleFetches = 0;
    for (final sat in selected) {
      try {
        // --- Fetch TLE using cache layer ---
        final tle = await _TleCache.getTleLines(sat);
        if (tle == null) {
          _logger.warning('[FFI] No TLE available for ${sat.name} (cache/network failed)');
          continue;
        }
        final (tle1, tle2) = tle;
        if (tle1.isEmpty || tle2.isEmpty) {
          _logger.warning('[FFI] Empty TLE lines for ${sat.name}');
          continue;
        }
        // Count a successful TLE acquisition even if it yields 0 transits
        lastSuccessfulTleFetches++;
        final results = predictTransits(
          tle1: tle1,
          tle2: tle2,
          lat: lat,
          lon: lon,
          altM: altM,
          startUtc: startUtc,
          endUtc: endUtc,
          nearMarginDeg: nearMarginDeg,
          maxDistanceKm: maxDistanceKm,
        );
        allResults.addAll(results.map((t) => t.copyWith(satellite: sat.name)));
      } catch (e, st) {
        _logger.warning('[FFI] Exception for ${sat.name}: $e\n$st');
      }
    }
    return allResults;
  }

  static Future<void> clearTleCacheForSatellite(Satellite sat) async => _TleCache.clearForSatellite(sat.noradId);
  static Future<void> clearAllTleCache() async => _TleCache.clearAll();
  static Future<void> forceRefreshTleForSatellite(Satellite sat) async => _TleCache.forceRefresh(sat);
  static Future<void> prefetchTles(List<Satellite> satellites) async {
    // Fire network/cache retrieval for each satellite to warm cache.
    for (final sat in satellites) {
      try {
        final res = await _TleCache.getTleLines(sat);
        if (res != null) {
          _logger.fine('[Prefetch] Cached TLE for ${sat.name}');
        } else {
          _logger.fine('[Prefetch] No TLE (yet) for ${sat.name}');
        }
      } catch (e, st) {
        _logger.fine('[Prefetch] Exception for ${sat.name}: $e\n$st');
      }
    }
  }
}

class _TleCache {
  static const _ttl = Duration(hours: 12);
  static const _maxStale = Duration(days: 3); // fallback usage window

  static String _key(int noradId) => 'tle_cache_$noradId';

  static Future<(String,String)?> getTleLines(Satellite sat, {bool forceNetwork = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _key(sat.noradId);
    final now = DateTime.now().toUtc();

    (String,String)? parseAndValidate(String raw, {bool allowStale = false}) {
      try {
        final obj = json.decode(raw) as Map<String, dynamic>;
        final fetchedMs = (obj['fetched'] ?? 0) as int;
        final fetched = DateTime.fromMillisecondsSinceEpoch(fetchedMs, isUtc: true);
        final age = now.difference(fetched);
        if (!allowStale && age > _ttl) return null;
        if (allowStale && age > _maxStale) return null; // too old
        final l1 = (obj['l1'] ?? '') as String;
        final l2 = (obj['l2'] ?? '') as String;
        if (l1.startsWith('1 ') && l2.startsWith('2 ')) {
          return (l1, l2);
        }
      } catch (_) {}
      return null;
    }

    if (!forceNetwork) {
      // Try fresh cache first
      final cachedRaw = prefs.getString(key);
      if (cachedRaw != null) {
        final cached = parseAndValidate(cachedRaw);
        if (cached != null) {
          return cached;
        }
      }
    }

    // Need refresh: fetch from network
    try {
      final resp = await http.get(Uri.parse(sat.tleUrl));
      if (resp.statusCode == 200) {
        final lines = resp.body.split('\n').where((l) => l.trim().isNotEmpty).toList();
        String? l1; String? l2;
        if (lines.length >= 3 && !lines[0].startsWith('1 ')) {
          l1 = lines.firstWhere((l) => l.startsWith('1 '), orElse: () => '');
          l2 = lines.firstWhere((l) => l.startsWith('2 '), orElse: () => '');
        } else {
          l1 = lines.firstWhere((l) => l.startsWith('1 '), orElse: () => '');
          l2 = lines.firstWhere((l) => l.startsWith('2 '), orElse: () => '');
        }
        if (l1.isNotEmpty && l2.isNotEmpty) {
          final payload = json.encode({
            'fetched': now.millisecondsSinceEpoch,
            'l1': l1.trim(),
            'l2': l2.trim(),
          });
          await prefs.setString(key, payload);
          return (l1.trim(), l2.trim());
        }
      }
    } catch (e) {
      NativeCore._logger.warning('[TLECache] Network fetch failed for ${sat.name}: $e');
    }

    // Fallback: allow stale cache (<= _maxStale) if available
    if (forceNetwork == false) {
      final cachedRaw = prefs.getString(key);
      if (cachedRaw != null) {
        final stale = parseAndValidate(cachedRaw, allowStale: true);
        if (stale != null) {
          NativeCore._logger.info('[TLECache] Using stale TLE for ${sat.name}');
          return stale;
        }
      }
    }

    return null; // no usable TLE
  }

  static Future<void> clearForSatellite(int noradId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(noradId));
  }

  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith('tle_cache_')).toList();
    for (final k in keys) { await prefs.remove(k); }
  }

  static Future<void> forceRefresh(Satellite sat) async {
    await clearForSatellite(sat.noradId);
    await getTleLines(sat, forceNetwork: true); // trigger immediate fetch
  }
}
