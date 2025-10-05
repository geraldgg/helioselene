import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:geolocator/geolocator.dart';
import '../core/ffi.dart';
import '../models/transit.dart';
import '../models/satellite.dart';
import '../widgets/transit_visual.dart'; // added for preview images
import 'transit_detail.dart'; // navigation to detail page

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
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
  bool _locating = false;

  @override
  void initState() {
    super.initState();
    _initLocation();
  }

  Future<void> _initLocation() async {
    setState(() { _locating = true; _error = null; });
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
        _altM = pos.altitude.isFinite ? pos.altitude : 0.0;
      });
    } catch (e) {
      setState(() { _error = 'Failed to get location: $e'; });
    } finally {
      setState(() { _locating = false; });
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
      final DateTime startUtc = DateTime.now().toUtc();
      final DateTime endUtc = startUtc.add(const Duration(days: 15));
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

  @override
  Widget build(BuildContext context) {
    // Use local time formatting now (no timezone label)
    final dateFmt = DateFormat('yyyy-MM-dd HH:mm:ss');
    final coordsText = (_lat != null && _lon != null)
        ? 'Lat: ${_lat!.toStringAsFixed(5)}  Lon: ${_lon!.toStringAsFixed(5)}  Alt: ${(_altM ?? 0).toStringAsFixed(0)} m'
        : _locating ? 'Locating…' : 'Location unknown';
    return Scaffold(
      appBar: AppBar(title: const Text('HelioSelene Transits')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(coordsText)),
                IconButton(
                  icon: const Icon(Icons.my_location),
                  tooltip: 'Refresh location',
                  onPressed: _busy ? null : _initLocation,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Card(
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Satellites', style: TextStyle(fontWeight: FontWeight.bold)),
                    ..._satellites.map((sat) => CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: Text(sat.name),
                          value: sat.selected,
                          onChanged: _busy ? null : (v) {
                            setState(() { sat.selected = v ?? false; });
                          },
                        )),
                    Row(
                      children: [
                        const Text('Max distance (km):'),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Slider(
                            value: _maxDistanceKm,
                            min: 0,
                            max: 200,
                            divisions: 200,
                            label: _maxDistanceKm.toStringAsFixed(0),
                            onChanged: _busy ? null : (v) => setState(()=> _maxDistanceKm = v),
                          ),
                        ),
                        SizedBox(
                          width: 48,
                          child: Text(_maxDistanceKm.toStringAsFixed(0), textAlign: TextAlign.end),
                        )
                      ],
                    )
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _busy ? null : _runPrediction,
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Predict next 15 days'),
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
                      separatorBuilder: (_, __) => const Divider(),
                      itemBuilder: (context, i) {
                        final e = _events[i];
                        final satLabel = e.satellite ?? 'Unknown';
                        final localTime = e.timeUtc.toLocal();
                        final durationStr = e.durationSeconds > 0
                            ? e.durationSeconds.toStringAsFixed(2)
                            : '-';
                        final dir = _compassDir(e.satAzDeg);
                        return ListTile(
                          leading: SizedBox(
                            width: 64,
                            height: 64,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Expanded(
                                  child: TransitVisual(
                                    key: ValueKey('transit-mini-$i-${e.timeUtc.toIso8601String()}'),
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
                          title: Text('${e.body} — ${e.kind}'),
                          subtitle: Text(
                            'When: ${dateFmt.format(localTime)}\n'
                            'Distance: ${e.issRangeKm.toStringAsFixed(0)} km  Dur: $durationStr s\n'
                            'Alt: ${e.satAltitudeDeg.toStringAsFixed(1)}°  Az: ${e.satAzDeg.toStringAsFixed(1)}° ${dir.isNotEmpty ? '($dir)' : ''}'
                          ),
                          isThreeLine: true,
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => TransitDetailPage(transit: e),
                              ),
                            );
                          },
                          trailing: const Icon(Icons.chevron_right),
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
                    color: Colors.red.withOpacity(0.1),
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
