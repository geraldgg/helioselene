import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';
import 'dart:io' show Platform;
import 'dart:convert';
import 'package:logging/logging.dart';
import 'package:http/http.dart' as http;

import '../models/transit.dart';
import '../models/satellite.dart';

typedef _PredictTransitsNative = ffi.Pointer<ffi.Char> Function(
  ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, // tle1, tle2
  ffi.Double, ffi.Double, ffi.Double, // lat, lon, alt_m
  ffi.Int64, ffi.Int64,               // start_epoch, end_epoch (UTC seconds)
  ffi.Double                          // near_arcmin
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

  static ffi.DynamicLibrary _open() {
    if (Platform.isAndroid) {
      return ffi.DynamicLibrary.open('libisscore.so');
    } else if (Platform.isWindows) {
      // for desktop testing (if you ever build a DLL)
      return ffi.DynamicLibrary.open('isscore.dll');
    } else if (Platform.isLinux) {
      return ffi.DynamicLibrary.open('libisscore.so');
    } else if (Platform.isMacOS || Platform.isIOS) {
      // iOS/macOS later: use DynamicLibrary.process() if linked statically
      return ffi.DynamicLibrary.process();
    }
    throw UnsupportedError('Unsupported platform');
  }

  static final ffi.DynamicLibrary _lib = _open();

  static final _predict = _lib
      .lookupFunction<_PredictTransitsNative, _PredictTransitsDart>('predict_transits_v2');
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
    double nearArcmin = 10.0,
  }) {
    final startEpoch = startUtc.toUtc().millisecondsSinceEpoch ~/ 1000;
    final endEpoch = endUtc.toUtc().millisecondsSinceEpoch ~/ 1000;
    _logger.info('[FFI] predictTransits called with:');
    _logger.info('  tle1: $tle1');
    _logger.info('  tle2: $tle2');
    _logger.info('  lat: $lat, lon: $lon, altM: $altM');
    _logger.info('  startEpoch: $startEpoch, endEpoch: $endEpoch');
    _logger.info('  nearArcmin: $nearArcmin');
    final tle1Ptr = tle1.toNativeUtf8().cast<ffi.Char>();
    final tle2Ptr = tle2.toNativeUtf8().cast<ffi.Char>();
    try {
      final ptr = _predict(
        tle1Ptr, tle2Ptr,
        lat, lon, altM,
        startEpoch, endEpoch,
        nearArcmin,
      );
      if (ptr == ffi.nullptr) {
        _logger.severe('[FFI] predict_transits_v2 returned null pointer');
        throw Exception('Native predict_transits_v2 returned null');
      }
      final jsonStr = ptr.cast<Utf8>().toDartString();
      _logger.info('[FFI] Raw JSON from native: $jsonStr');
      _freeJson(ptr);
      final List<dynamic> decoded = json.decode(jsonStr);
      _logger.info('[FFI] Decoded JSON: $decoded');
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
    double nearArcmin = 10.0,
  }) async {
    List<Transit> allResults = [];
    for (final sat in satellites.where((s) => s.selected)) {
      try {
        // Fetch TLE lines from the satellite's TLE URL
        final tleResp = await http.get(Uri.parse(sat.tleUrl));
        if (tleResp.statusCode != 200) {
          _logger.warning('[FFI] Failed to fetch TLE for ${sat.name}');
          continue;
        }
        final lines = tleResp.body.split('\n').where((l) => l.trim().isNotEmpty).toList();
        String? tle1, tle2;
        if (lines.length >= 3 && !lines[0].startsWith('1 ')) {
          tle1 = lines[1].trim();
          tle2 = lines[2].trim();
        } else {
          tle1 = lines.firstWhere((l) => l.startsWith('1 '), orElse: () => '');
          tle2 = lines.firstWhere((l) => l.startsWith('2 '), orElse: () => '');
        }
        if (tle1.isEmpty || tle2.isEmpty) {
          _logger.warning('[FFI] Could not parse TLE for ${sat.name}');
          continue;
        }
        final results = predictTransits(
          tle1: tle1,
          tle2: tle2,
          lat: lat,
          lon: lon,
          altM: altM,
          startUtc: startUtc,
          endUtc: endUtc,
          nearArcmin: nearArcmin,
        );
        allResults.addAll(results.map((t) => t.copyWith(satellite: sat.name)));
      } catch (e, st) {
        _logger.warning('[FFI] Exception for ${sat.name}: $e\n$st');
      }
    }
    return allResults;
  }
}
