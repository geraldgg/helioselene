import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary; // added for image capture
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
            if (chordInfo.isTransit) Text('Chord length: ${chordInfo.chordArcmin.toStringAsFixed(2)} arcmin (fraction of diameter ${(chordInfo.chordArcmin / (2 * transit.targetRadiusArcmin)).toStringAsFixed(2)})'),
            const SizedBox(height: 12),
            Expanded(
              child: Center(
                child: TransitVisual(
                  transit: transit,
                  chordInfo: chordInfo,
                  showLegend: true,
                  mini: false,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      final boundary = chordInfo.repaintKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
                      if (boundary == null) return;
                      final img = await boundary.toImage(pixelRatio: 3.0);
                      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
                      if (bytes == null || !context.mounted) return;
                      await showDialog(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: const Text('PNG Generated'),
                          content: Text('Size: ${bytes.lengthInBytes} bytes'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))
                          ],
                        ),
                      );
                    },
                    icon: const Icon(Icons.save_alt),
                    label: const Text('Generate Image'),
                  ),
                ),
              ],
            )
          ],
        ),
      ),
    );
  }
}
