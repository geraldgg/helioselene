import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

/// Returns (lat, lon, altitudeMeters or null)
class LocationPickerResult {
  final double latitude;
  final double longitude;
  final double? altitudeM;
  LocationPickerResult(this.latitude, this.longitude, this.altitudeM);
}

class LocationPickerPage extends StatefulWidget {
  final double? initialLat;
  final double? initialLon;
  const LocationPickerPage({super.key, this.initialLat, this.initialLon});

  @override
  State<LocationPickerPage> createState() => _LocationPickerPageState();
}

class _LocationPickerPageState extends State<LocationPickerPage> {
  late final MapController _mapController;
  LatLng? _picked;
  double? _altitude; // meters
  bool _loadingAlt = false;
  String? _altError;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    if (widget.initialLat != null && widget.initialLon != null) {
      _picked = LatLng(widget.initialLat!, widget.initialLon!);
    }
  }

  Future<void> _fetchAltitude(LatLng pos) async {
    setState(() { _loadingAlt = true; _altError = null; _altitude = null; });
    try {
      // Open-Elevation simple API. If it fails we silently continue with null altitude.
      final uri = Uri.parse('https://api.open-elevation.com/api/v1/lookup?locations=' + pos.latitude.toStringAsFixed(6) + ',' + pos.longitude.toStringAsFixed(6));
      final resp = await http.get(uri).timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final jsonMap = json.decode(resp.body) as Map<String, dynamic>;
        final results = jsonMap['results'];
        if (results is List && results.isNotEmpty) {
          final first = results.first;
            final elev = first['elevation'];
            if (elev is num) {
              _altitude = elev.toDouble();
            }
        }
      } else {
        _altError = 'Elevation HTTP ${resp.statusCode}';
      }
    } catch (e) {
      _altError = 'Elevation failed: $e';
    } finally {
      if (mounted) setState(() { _loadingAlt = false; });
    }
  }

  void _onTapTap(TapPosition tapPosition, LatLng latlng) {
    setState(() { _picked = latlng; });
    _fetchAltitude(latlng);
  }

  @override
  Widget build(BuildContext context) {
    final center = _picked ?? LatLng(widget.initialLat ?? 0, widget.initialLon ?? 0);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pick Location'),
        actions: [
          // Keep USE in app bar for power users, but main action is now bottom Validate button
          if (_picked != null)
            TextButton.icon(
              onPressed: () {
                Navigator.of(context).pop(LocationPickerResult(_picked!.latitude, _picked!.longitude, _altitude));
              },
              icon: const Icon(Icons.check, size: 18),
              label: const Text('USE'),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: center,
                initialZoom: (_picked == null) ? 2.0 : 8.5,
                onTap: _onTapTap,
                interactionOptions: const InteractionOptions(flags: ~InteractiveFlag.rotate),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'helioselene',
                  tileProvider: NetworkTileProvider(),
                ),
                if (_picked != null)
                  MarkerLayer(markers: [
                    Marker(
                      point: _picked!,
                      width: 46, height: 46,
                      alignment: Alignment.center,
                      child: AnimatedScale(
                        scale: 1.0,
                        duration: const Duration(milliseconds: 250),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.15),
                            shape: BoxShape.circle,
                            border: Border.all(color: Theme.of(context).colorScheme.secondary, width: 2),
                          ),
                          child: const Icon(Icons.location_on, color: Colors.redAccent, size: 28),
                        ),
                      ),
                    )
                  ]),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(top: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.2))),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 6,
                  offset: const Offset(0,-2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _picked == null
                          ? const Text('Tap the map to select a location', style: TextStyle(fontStyle: FontStyle.italic))
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Lat: ' + _picked!.latitude.toStringAsFixed(5) + '  Lon: ' + _picked!.longitude.toStringAsFixed(5)),
                                if (_loadingAlt) const Padding(padding: EdgeInsets.only(top:4), child: SizedBox(height:14, width:14, child: CircularProgressIndicator(strokeWidth:2))),
                                if (!_loadingAlt && _altitude != null) Text('Approx altitude: ' + _altitude!.toStringAsFixed(0) + ' m'),
                                if (_altError != null) Text(_altError!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                              ],
                            ),
                    ),
                    if (_picked != null)
                      IconButton(
                        tooltip: 'Recenter on selection',
                        icon: const Icon(Icons.center_focus_strong),
                        onPressed: () => _mapController.move(_picked!, 11.0),
                      )
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                        label: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _picked == null ? null : () {
                          Navigator.of(context).pop(LocationPickerResult(_picked!.latitude, _picked!.longitude, _altitude));
                        },
                        icon: const Icon(Icons.check_circle_outline),
                        label: const Text('Use'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          )
        ],
      ),
    );
  }
}
