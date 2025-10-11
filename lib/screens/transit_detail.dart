import 'package:flutter/material.dart';
import '../models/transit.dart';
import '../widgets/transit_visual.dart';
import 'transit_map_page.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'dart:math' as math;
import '../core/shared_tile_provider.dart';

class TransitDetailPage extends StatefulWidget {
  final Transit transit;
  final double observerLat;
  final double observerLon;
  const TransitDetailPage({super.key, required this.transit, required this.observerLat, required this.observerLon});

  @override
  State<TransitDetailPage> createState() => _TransitDetailPageState();
}

class _TransitDetailPageState extends State<TransitDetailPage> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final transit = widget.transit;
    final observerLat = widget.observerLat;
    final observerLon = widget.observerLon;
    final chordInfo = ChordInfo.fromTransit(transit, repaintKey: GlobalKey());
    final summaryItems = <Widget>[
      Text('When (local): ${transit.timeUtc.toLocal()}'),
      Text('Satellite: ${transit.satellite ?? 'Unknown'}'),
      Text('Distance: ${transit.issRangeKm.toStringAsFixed(0)} km  •  Duration: ${transit.durationSeconds.toStringAsFixed(2)} s'),
      Text('Angular sep: ${transit.minSeparationArcmin.toStringAsFixed(2)} arcmin'),
      if (chordInfo.isTransit) Text('Chord: ${chordInfo.chordArcmin.toStringAsFixed(2)} arcmin (${(chordInfo.chordArcmin / (2 * transit.targetRadiusArcmin)).toStringAsFixed(2)} dia)')
    ];

    final detailedItems = <Widget>[
      Text('Altitude: Sat ${transit.satAltitudeDeg.toStringAsFixed(1)}° / Body ${transit.bodyAltitudeDeg.toStringAsFixed(1)}°'),
      Text('Azimuth: ${transit.satAzDeg.toStringAsFixed(1)}°'),
      Text('Target radius: ${transit.targetRadiusArcmin.toStringAsFixed(2)} arcmin'),
      Text('Motion dir: ${transit.motionDirectionDeg.toStringAsFixed(1)}°'),
      Text('vAlt: ${transit.velocityAltDegPerS.toStringAsFixed(3)}°/s  vAz: ${transit.velocityAzDegPerS.toStringAsFixed(3)}°/s'),
    ];

    return Scaffold(
      appBar: AppBar(title: Text('${transit.body} ${transit.kind}')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Summary block + expand toggle
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ...summaryItems,
                    if (_expanded) ...detailedItems.map((w) => Padding(padding: const EdgeInsets.only(top: 2), child: w)),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        style: TextButton.styleFrom(padding: EdgeInsets.zero),
                        onPressed: () => setState(() => _expanded = !_expanded),
                        icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                        label: Text(_expanded ? 'Less' : 'More'),
                      ),
                    ),
                  ],
                ),
              ),
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
              Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
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
                  child: _MiniTransitMap(
                    transit: transit,
                    observerLat: observerLat,
                    observerLon: observerLon,
                  ),
                ),
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
            IgnorePointer( // ensure map preview doesn't consume taps so InkWell works
              child: FlutterMap(
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
                    tileProvider: SharedTileProvider.osm,
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
                          color: theme.colorScheme.primary.withValues(alpha: 0.15),
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
            ),
            Positioned(
              top: 6,
              left: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
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
      child: map,
    );
  }
}
