import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:ui' show lerpDouble; // added for hero scaling
import 'dart:async' show unawaited; // for unawaited background futures
import '../core/ffi.dart';
import '../models/transit.dart';
import '../models/satellite.dart';
import '../widgets/transit_visual.dart'; // added for preview images
import 'transit_detail.dart'; // navigation to detail page
import 'location_picker_page.dart'; // added for manual location selection
import 'package:http/http.dart' as http; // for fallback altitude lookup
import 'dart:convert'; // for decoding elevation service

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final DateFormat dateFmt = DateFormat('yyyy-MM-dd HH:mm');
  List<Transit> _events = [];
  bool _busy = false;
  String? _error;
  final List<Satellite> _satellites = Satellite.supportedSatellites
      .map((s) => Satellite(name: s.name, noradId: s.noradId, tleUrl: s.tleUrl, selected: true))
      .toList();
  double _maxDistanceKm = 35.0;
  double? _lat;
  double? _lon;
  double? _altM;
  bool _autoAltFetching = false; // indicates background altitude fetch after GPS

  @override
  void initState() {
    super.initState();
    _initLocation();
  }

  // Fallback approximate altitude acquisition using Open-Elevation
  Future<void> _maybeFetchApproxAltitude(double lat, double lon) async {
    if (!mounted) return;
    // If we already have a non-zero altitude (|alt| > ~1 m), skip
    if (_altM != null && _altM!.abs() > 1.0) return;
    setState(() { _autoAltFetching = true; });
    try {
      final uri = Uri.parse('https://api.open-elevation.com/api/v1/lookup?locations=${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}');
      final resp = await http.get(uri).timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final map = json.decode(resp.body) as Map<String, dynamic>;
        final results = map['results'];
        if (results is List && results.isNotEmpty) {
          final elev = results.first['elevation'];
          if (elev is num) {
            if (!mounted) return; // safety
            // Only override if altitude still unknown or ~0
            if (_altM == null || _altM!.abs() <= 1.0) {
              setState(() { _altM = elev.toDouble(); });
            }
          }
        }
      }
    } catch (_) {
      // silent fail; keep existing altitude
    } finally {
      if (mounted) setState(() { _autoAltFetching = false; });
    }
  }

  Future<void> _initLocation() async {
    setState(() { _error = null; });
    try {
      final hasPerm = await _ensureLocationPermission();
      if (!hasPerm) {
        setState(() { _error = 'Location permission denied'; });
        return;
      }
      final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      setState(() {
        _lat = pos.latitude;
        _lon = pos.longitude;
        // Geolocator altitude may be 0 on some desktop platforms; capture but allow fallback.
        _altM = (pos.altitude.isFinite) ? pos.altitude : null;
      });
      if (_lat != null && _lon != null) {
        // Trigger background approximate altitude fetch if current altitude is null/near zero.
        unawaited(_maybeFetchApproxAltitude(_lat!, _lon!));
      }
    } catch (e) {
      setState(() { _error = 'Failed to get location: $e'; });
    } finally {

    }
  }

  Future<bool> _ensureLocationPermission() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _error = 'Location services disabled';
      return false;
    }
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return false;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      _error = 'Location permission permanently denied';
      return false;
    }
    return true;
  }

  Future<void> _runPrediction() async {
    setState(() { _busy = true; _error = null; _events = []; });
    try {
      if (_satellites.where((s) => s.selected).isEmpty) {
        setState(() { _error = 'Select at least one satellite.'; });
        return;
      }
      if (_lat == null || _lon == null) {
        await _initLocation();
        if (_lat == null || _lon == null) {
          setState(() { _error = 'Location unavailable'; });
          return;
        }
      }
      // Use current UTC hour rounded down as start time
      final now = DateTime.now().toUtc();
      final startUtc = DateTime.utc(now.year, now.month, now.day, now.hour);
      final endUtc = startUtc.add(const Duration(days: 15));
      final results = await NativeCore.predictTransitsForSatellites(
        satellites: _satellites,
        lat: _lat!,
        lon: _lon!,
        altM: _altM ?? 0.0,
        startUtc: startUtc,
        endUtc: endUtc,
        maxDistanceKm: _maxDistanceKm,
      );
      results.sort((a,b)=> a.timeUtc.compareTo(b.timeUtc));
      final successCount = NativeCore.lastSuccessfulTleFetches;
      setState(() {
        _events = results;
        if (successCount == 0) {
          _error = 'Satellite positions could not be retrieved (TLE data unavailable). Check your network or try again later.';
        } else if (results.isEmpty) {
          _error = 'No transits predicted in the next 15 days for the selected satellites.';
        } else {
          _error = null; // ensure cleared
        }
      });
    } catch (e) {
      setState(() { _error = e.toString(); });
    } finally {
      setState(() { _busy = false; });
    }
  }

  String _compassDir(double azDeg) {
    if (azDeg.isNaN || !azDeg.isFinite) return '';
    final dirs = [
      'N','NNE','NE','ENE','E','ESE','SE','SSE','S','SSW','SW','WSW','W','WNW','NW','NNW'
    ];
    double az = azDeg % 360.0;
    if (az < 0) az += 360.0;
    final idx = ((az / 22.5) + 0.5).floor() % 16; // 360/16 = 22.5
    return dirs[idx];
  }

  Future<void> _pickLocation() async {
    if (_busy) return;
    final result = await Navigator.of(context).push<LocationPickerResult>(
      MaterialPageRoute(
        builder: (_) => LocationPickerPage(
          initialLat: _lat,
          initialLon: _lon,
        ),
      ),
    );
    if (result != null) {
      setState(() {
        _lat = result.latitude;
        _lon = result.longitude;
        // Prefer picked altitude if available, else keep existing or 0
        if (result.altitudeM != null && result.altitudeM!.isFinite) {
          _altM = result.altitudeM;
        } else {
          _altM = _altM ?? 0.0;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('HelioSelene Transit'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => _SettingsPage(_satellites, _maxDistanceKm, (sats, dist) {
                  setState(() {
                    for (int i = 0; i < _satellites.length; i++) {
                      _satellites[i].selected = sats[i].selected;
                    }
                    _maxDistanceKm = dist;
                  });
                }))
              );
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Location info card with action icons
            Card(
              elevation: 2,
              margin: const EdgeInsets.only(bottom: 16),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Your location', style: Theme.of(context).textTheme.labelMedium),
                          const SizedBox(height: 4),
                          Text('Lat: ${_lat?.toStringAsFixed(5) ?? '—'}'),
                          Text('Lon: ${_lon?.toStringAsFixed(5) ?? '—'}'),
                          Text('Alt: ${_altM != null ? '${_altM!.toStringAsFixed(0)} m${(_autoAltFetching && (_altM == null || _altM!.abs() <= 1.0)) ? ' (updating…)' : ''}' : (_autoAltFetching ? '…' : '—')}'),
                        ],
                      ),
                    ),
                    Column(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.my_location),
                          tooltip: 'Refresh GPS location',
                          onPressed: _busy ? null : _initLocation,
                        ),
                        IconButton(
                          icon: const Icon(Icons.map),
                          tooltip: 'Pick location on map',
                          onPressed: _busy ? null : _pickLocation,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            // Prediction row
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _busy ? null : _runPrediction,
                    icon: const Icon(Icons.auto_awesome),
                    label: const Text('Predict next 15 days'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_busy) const LinearProgressIndicator(),
            const SizedBox(height: 8),
            Expanded(
              child: _events.isEmpty
                  ? Center(
                      child: Text(
                        _error != null && NativeCore.lastSuccessfulTleFetches == 0
                            ? 'TLE data unavailable.'
                            : 'No events yet. Select satellites and tap Predict.',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.separated(
                      itemCount: _events.length,
                      separatorBuilder: (context, index) => const Divider(),
                      itemBuilder: (context, i) {
                        final e = _events[i];
                        final satLabel = e.satellite ?? 'Unknown';
                        final localTime = e.timeUtc.toLocal();
                        final durationStr = e.durationSeconds > 0
                            ? e.durationSeconds.toStringAsFixed(2)
                            : '-';
                        final dir = _compassDir(e.satAzDeg);
                        // Custom row to ensure vertical centering between preview and text
                        return InkWell(
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => TransitDetailPage(
                                  transit: e,
                                  observerLat: _lat!,
                                  observerLon: _lon!,
                                ),
                              ),
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8.0),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                SizedBox(
                                  width: 72,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Hero(
                                        tag: 'transit-${e.timeUtc.toIso8601String()}',
                                        flightShuttleBuilder: (flightContext, animation, direction, fromContext, toContext) {
                                          final curved = CurvedAnimation(parent: animation, curve: Curves.easeInOut);
                                          final baseColor = e.body == 'Sun' ? Colors.orangeAccent : Colors.blueGrey;
                                          // Determine source and destination sizes
                                          final fromSize = (fromContext.findRenderObject() as RenderBox?)?.size;
                                          final toSize = (toContext.findRenderObject() as RenderBox?)?.size;
                                          final src = fromSize?.shortestSide ?? 56.0;
                                          final dstRaw = toSize?.shortestSide;
                                          // If destination size not yet known, assume a target upscale (e.g., 260)
                                          final dst = (dstRaw != null && dstRaw > 0) ? dstRaw : 260.0;
                                          final scaleTween = Tween<double>(begin: 1.0, end: dst / src);
                                          return AnimatedBuilder(
                                            animation: curved,
                                            builder: (_, child) {
                                              final t = curved.value;
                                              final forward = direction == HeroFlightDirection.push;
                                              final haloT = forward ? t : (1 - t);
                                              final haloOpacity = (1 - haloT) * 0.5; // fades out as it approaches
                                              final haloScale = lerpDouble(0.6, 1.3, haloT)!;
                                              final scale = scaleTween.transform(t);
                                              return Transform.scale(
                                                scale: scale,
                                                child: Stack(
                                                  alignment: Alignment.center,
                                                  children: [
                                                    Opacity(
                                                      opacity: haloOpacity.clamp(0.0, 0.5),
                                                      child: Transform.scale(
                                                        scale: haloScale,
                                                        child: Container(
                                                          decoration: BoxDecoration(
                                                            shape: BoxShape.circle,
                                                            gradient: RadialGradient(
                                                              colors: [
                                                                baseColor.withValues(alpha: 0.35),
                                                                baseColor.withValues(alpha: 0.05),
                                                                Colors.transparent,
                                                              ],
                                                              stops: const [0.0, 0.5, 1.0],
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                    child!,
                                                  ],
                                                ),
                                              );
                                            },
                                            child: SizedBox(
                                              width: src, // build at source size and scale up for sharpness tradeoff
                                              height: src,
                                              child: TransitVisual(
                                                transit: e,
                                                mini: true,
                                                showLegend: false,
                                                size: src,
                                              ),
                                            ),
                                          );
                                        },
                                        child: TransitVisual(
                                          transit: e,
                                          mini: true,
                                          showLegend: false,
                                          size: 56,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        satLabel.split(' ').first,
                                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        '${e.body} — ${e.kind}',
                                        style: Theme.of(context).textTheme.titleSmall,
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'When: ${dateFmt.format(localTime)}',
                                        style: Theme.of(context).textTheme.bodySmall,
                                      ),
                                      Text(
                                        'Distance: ${e.issRangeKm.toStringAsFixed(0)} km  Dur: $durationStr s',
                                        style: Theme.of(context).textTheme.bodySmall,
                                      ),
                                      Text(
                                        'Alt: ${e.satAltitudeDeg.toStringAsFixed(1)}°  Az: ${e.satAzDeg.toStringAsFixed(1)}° ${dir.isNotEmpty ? '($dir)' : ''}',
                                        style: Theme.of(context).textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Icon(Icons.chevron_right, size: 20),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              AnimatedOpacity(
                duration: const Duration(milliseconds: 300),
                opacity: 1.0,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.redAccent),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.error_outline, color: Colors.redAccent, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _error!,
                          style: const TextStyle(color: Colors.redAccent),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18, color: Colors.redAccent),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: () => setState(() => _error = null),
                        tooltip: 'Dismiss',
                      )
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// Settings page for satellite selection and max distance
class _SettingsPage extends StatefulWidget {
  final List<Satellite> satellites;
  final double maxDistanceKm;
  final void Function(List<Satellite>, double) onSave;
  const _SettingsPage(this.satellites, this.maxDistanceKm, this.onSave);
  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}
class _SettingsPageState extends State<_SettingsPage> {
  late List<Satellite> _satellites;
  late double _maxDistanceKm;
  @override
  void initState() {
    super.initState();
    _satellites = widget.satellites.map((s) => Satellite(name: s.name, noradId: s.noradId, tleUrl: s.tleUrl, selected: s.selected)).toList();
    _maxDistanceKm = widget.maxDistanceKm;
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Satellites', style: Theme.of(context).textTheme.titleMedium),
            ..._satellites.map((sat) => CheckboxListTile(
              title: Text(sat.name),
              value: sat.selected,
              onChanged: (v) {
                setState(() { sat.selected = v ?? false; });
              },
            )),
            const SizedBox(height: 16),
            Text('Max travel distance (km)', style: Theme.of(context).textTheme.titleMedium),
            Slider(
              min: 0,
              max: 100,
              divisions: 20,
              value: _maxDistanceKm,
              label: _maxDistanceKm.toStringAsFixed(0),
              onChanged: (v) { setState(() { _maxDistanceKm = v; }); },
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () {
                widget.onSave(_satellites, _maxDistanceKm);
                Navigator.of(context).pop();
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}
