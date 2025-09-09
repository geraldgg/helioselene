import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';
import 'dart:io' show Platform;
import 'dart:convert';

import '../models/transit.dart';

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
        throw Exception('Native predict_transits_v2 returned null');
      }
      final jsonStr = ptr.cast<Utf8>().toDartString();
      _freeJson(ptr);
      final List<dynamic> decoded = json.decode(jsonStr);
      return decoded.map((e) => Transit.fromJson(e)).toList();
    } finally {
      malloc.free(tle1Ptr);
      malloc.free(tle2Ptr);
    }
  }
}
