import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;

class _CachingTileProvider extends TileProvider {
  final Directory cacheDir;
  final http.Client _client = http.Client();
  static int _cacheHits = 0;
  static int _networkLoads = 0;
  static int _printedCache = 0;
  static int _printedNet = 0;
  static const int _printLimitPerKind = 5;
  static const String _userAgent = 'HelioSelene/1.0 (+https://github.com/your-org/helioselene)';

  _CachingTileProvider(this.cacheDir);

  String _tilePath(TileCoordinates c) =>
      '${cacheDir.path}/${c.z}/${c.x}/${c.y}.png';

  void _log({required bool cache}) {
    if (cache) {
      _cacheHits++;
      if (_printedCache < _printLimitPerKind) {
        // ignore: avoid_print
        print('[Tiles] cache hit (#$_cacheHits)');
        _printedCache++;
      }
    } else {
      _networkLoads++;
      if (_printedNet < _printLimitPerKind) {
        // ignore: avoid_print
        print('[Tiles] network load (#$_networkLoads)');
        _printedNet++;
      }
    }
    final total = _cacheHits + _networkLoads;
    if (total % 25 == 0) {
      // ignore: avoid_print
      print('[Tiles] summary total=$total cache=$_cacheHits net=$_networkLoads');
    }
  }

  Future<void> _ensureDir(String path) async {
    final dir = Directory(path).parent; // path includes file name; parent ensures z/x directories
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  Future<void> _backgroundDownload(String url, String filePath) async {
    try {
      await _ensureDir(filePath);
      final resp = await _client.get(Uri.parse(url), headers: {'User-Agent': _userAgent});
      if (resp.statusCode == 200) {
        final file = File(filePath);
        await file.writeAsBytes(resp.bodyBytes, flush: false);
      }
    } catch (_) {/* silent */}
  }

  String _resolveUrl(TileLayer layer, TileCoordinates c) {
    // Only support urlTemplate (templateFunction is deprecated in flutter_map v6+)
    final template = layer.urlTemplate;
    if (template == null) {
      throw StateError('TileLayer.urlTemplate is required (templateFunction deprecated).');
    }
    String u = template
        .replaceAll('{z}', '${c.z}')
        .replaceAll('{x}', '${c.x}')
        .replaceAll('{y}', '${c.y}');
    // Basic subdomain support if template contains {s}
    if (u.contains('{s}') && layer.subdomains.isNotEmpty) {
      // Simple round-robin using coordinates hash
      final subs = layer.subdomains;
      final idx = (c.x + c.y + c.z) % subs.length;
      u = u.replaceAll('{s}', subs[idx]);
    }
    // Retina placeholder {r} if present (we do not serve @2x variant, just blank)
    if (u.contains('{r}')) {
      u = u.replaceAll('{r}', '');
    }
    return u;
  }

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final url = _resolveUrl(options, coordinates);
    final path = _tilePath(coordinates);
    final file = File(path);
    if (file.existsSync()) {
      _log(cache: true);
      return FileImage(file);
    } else {
      _backgroundDownload(url, path); // fire-and-forget
      _log(cache: false);
      return NetworkImage(url, headers: {'User-Agent': _userAgent});
    }
  }

  @override
  void dispose() {
    _client.close();
  }
}

class SharedTileProvider {
  static TileProvider? _provider;
  static bool _initializing = false;

  static Future<void> init() async {
    if (_provider != null || _initializing) return;
    _initializing = true;
    try {
      final baseDir = await getApplicationSupportDirectory();
      final tilesDir = Directory('${baseDir.path}/tile_cache');
      if (!await tilesDir.exists()) {
        await tilesDir.create(recursive: true);
      }
      _provider = _CachingTileProvider(tilesDir);
    } finally {
      _initializing = false;
    }
  }

  static TileProvider get osm => _provider ?? NetworkTileProvider();
}
