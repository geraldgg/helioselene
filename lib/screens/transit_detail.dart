import 'package:flutter/material.dart';
import '../models/transit.dart';
import '../widgets/transit_visual.dart';
import 'transit_map_page.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'dart:math' as math;

class TransitDetailPage extends StatelessWidget {
  final Transit transit;
  final double observerLat;
  final double observerLon;
  const TransitDetailPage({super.key, required this.transit, required this.observerLat, required this.observerLon});

  @override
  Widget build(BuildContext context) {
    // Compute chord info (with its own repaint key) for reuse in visualization + image export
    final chordInfo = ChordInfo.fromTransit(transit, repaintKey: GlobalKey());
    return Scaffold(
      appBar: AppBar(title: Text('${transit.body} ${transit.kind}')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('When (local): ${transit.timeUtc.toLocal()}'),
              Text('Satellite: ${transit.satellite ?? 'Unknown'}'),
              Text('Body: ${transit.body}'),
              Text('Distance: ${transit.issRangeKm.toStringAsFixed(0)} km'),
              Text('Altitude: ${transit.satAltitudeDeg.toStringAsFixed(1)}°  Body alt: ${transit.bodyAltitudeDeg.toStringAsFixed(1)}°'),
              Text('Azimuth: ${transit.satAzDeg.toStringAsFixed(1)}°'),
              Text('Duration: ${transit.durationSeconds.toStringAsFixed(2)} s'),
              Text('Angular sep: ${transit.minSeparationArcmin.toStringAsFixed(2)} arcmin'),
              Text('Target radius: ${transit.targetRadiusArcmin.toStringAsFixed(2)} arcmin'),
              Text('Motion dir: ${transit.motionDirectionDeg.toStringAsFixed(1)}°  vAlt: ${transit.velocityAltDegPerS.toStringAsFixed(3)}°/s  vAz: ${transit.velocityAzDegPerS.toStringAsFixed(3)}°/s'),
              if (chordInfo.isTransit) Text('Chord length: ${chordInfo.chordArcmin.toStringAsFixed(2)} arcmin (fraction of diameter ${(chordInfo.chordArcmin / (2 * transit.targetRadiusArcmin)).toStringAsFixed(2)})'),
              const SizedBox(height: 12),
              Center(
                child: Hero(
                  tag: 'transit-${transit.timeUtc.toIso8601String()}',
                  child: SizedBox(
                    width: 260,
                    height: 260,
                    child: TransitVisual(
                      transit: transit,
                      chordInfo: chordInfo,
                      showLegend: false,
                      mini: false,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Mini static map preview
              _MiniTransitMap(
                transit: transit,
                observerLat: observerLat,
                observerLon: observerLon,
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                icon: const Icon(Icons.map),
                label: const Text('Show visibility map'),
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => TransitMapPage(
                        transit: transit,
                        observerLat: observerLat,
                        observerLon: observerLon,
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniTransitMap extends StatelessWidget {
  final Transit transit;
  final double observerLat;
  final double observerLon;
  const _MiniTransitMap({required this.transit, required this.observerLat, required this.observerLon});

  LatLng _lookPoint(LatLng origin, double azimuthDeg, double km) {
    final d = Distance();
    return d.offset(origin, km * 1000, azimuthDeg);
  }

  @override
  Widget build(BuildContext context) {
    final center = LatLng(observerLat, observerLon);
    final lookDistanceKm = (transit.issRangeKm / 1500).clamp(0.8, 2.0); // dynamic look distance
    final look = _lookPoint(center, transit.satAzDeg, lookDistanceKm);

    double dynamicZoom() {
      final r = transit.issRangeKm;
      if (r < 600) return 15.0;
      if (r < 900) return 14.5;
      if (r < 1200) return 14.2;
      if (r < 1700) return 13.8;
      return 13.3;
    }
    final zoom = dynamicZoom();
    final theme = Theme.of(context);

    final map = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          children: [
            FlutterMap(
              options: MapOptions(
                initialCenter: center,
                initialZoom: zoom,
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.none, // static preview
                ),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'helioselene',
                  tileProvider: NetworkTileProvider(),
                ),
                PolylineLayer(polylines: [
                  Polyline(
                    points: [center, look],
                    color: Colors.redAccent,
                    strokeWidth: 3,
                  ),
                ]),
                MarkerLayer(markers: [
                  Marker(
                    point: center,
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: theme.colorScheme.primary.withOpacity(0.15),
                        border: Border.all(color: theme.colorScheme.primary, width: 2),
                      ),
                      child: const Center(child: Icon(Icons.my_location, size: 16)),
                    ),
                  ),
                  Marker(
                    point: look,
                    width: 44,
                    height: 44,
                    alignment: Alignment.center,
                    child: Transform.rotate(
                      angle: transit.satAzDeg * math.pi / 180.0,
                      child: Icon(
                        Icons.navigation,
                        size: 34,
                        color: Colors.redAccent,
                      ),
                    ),
                  ),
                ]),
              ],
            ),
            Positioned(
              top: 6,
              left: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.45),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Az ${transit.satAzDeg.toStringAsFixed(0)}° • Alt ${transit.satAltitudeDeg.toStringAsFixed(0)}°',
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return Hero(
      tag: 'map-${transit.timeUtc.toIso8601String()}',
      child: GestureDetector(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => TransitMapPage(
                transit: transit,
                observerLat: observerLat,
                observerLon: observerLon,
              ),
            ),
          );
        },
        child: map,
      ),
    );
  }
}
