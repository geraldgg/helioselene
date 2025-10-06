import 'package:flutter/material.dart';
import '../models/transit.dart';
import '../widgets/transit_visual.dart';

class TransitDetailPage extends StatelessWidget {
  final Transit transit;
  const TransitDetailPage({super.key, required this.transit});

  @override
  Widget build(BuildContext context) {
    // Compute chord info (with its own repaint key) for reuse in visualization + image export
    final chordInfo = ChordInfo.fromTransit(transit, repaintKey: GlobalKey());
    return Scaffold(
      appBar: AppBar(title: Text('${transit.body} ${transit.kind}')),
      body: Padding(
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
            const Spacer(),
          ],
        ),
      ),
    );
  }
}
