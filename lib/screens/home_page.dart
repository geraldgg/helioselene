import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../core/ffi.dart';
import '../models/transit.dart';
import '../models/satellite.dart';

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

  Future<void> _runPrediction() async {
    setState(() { _busy = true; _error = null; _events = []; });
    try {
      if (_satellites.where((s) => s.selected).isEmpty) {
        setState(() { _error = 'Select at least one satellite.'; });
        return;
      }

      final DateTime startUtc = DateTime.utc(2025, 10, 05, 18, 40, 0); // fixed window for now
      final DateTime endUtc = startUtc.add(const Duration(days: 15));
      final results = await NativeCore.predictTransitsForSatellites(
        satellites: _satellites,
        lat: 48.78698,
        lon: 2.49835,
        altM: 36,
        startUtc: startUtc,
        endUtc: endUtc,
        maxDistanceKm: _maxDistanceKm,
      );
      results.sort((a,b)=> a.timeUtc.compareTo(b.timeUtc));
      setState(() { _events = results; });
    } catch (e) {
      setState(() { _error = e.toString(); });
    } finally {
      setState(() { _busy = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('yyyy-MM-dd HH:mm:ss').addPattern(' UTC');
    return Scaffold(
      appBar: AppBar(title: const Text('HelioSelene Transits')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Satellite selection panel
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
              label: const Text('Predict next 14 days'),
            ),
            const SizedBox(height: 12),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 8),
            Expanded(
              child: _events.isEmpty
                  ? const Center(child: Text('No events yet. Select satellites and tap Predict.'))
                  : ListView.separated(
                      itemCount: _events.length,
                      separatorBuilder: (_, __) => const Divider(),
                      itemBuilder: (context, i) {
                        final e = _events[i];
                        final satLabel = e.satellite ?? 'Unknown';
                        return ListTile(
                          leading: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(satLabel.split(' ').first, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                            ],
                          ),
                          title: Text('${e.body} — ${e.kind}'),
                          subtitle: Text(
                            'Sat: $satLabel\n'
                            'When: ${dateFmt.format(e.timeUtc)}\n'
                            'Angular sep: ${e.minSeparationArcmin.toStringAsFixed(1)}\' (target radius: ${e.targetRadiusArcmin.toStringAsFixed(1)}\')  Az: ${e.satAzDeg.toStringAsFixed(1)}°\n'
                            'Sat alt: ${e.satAltitudeDeg.toStringAsFixed(1)}°  Body alt: ${e.bodyAltitudeDeg.toStringAsFixed(1)}°  Speed: ${e.speedArcminPerS.toStringAsFixed(2)}\'/s\n'
                            'Range: ${e.issRangeKm.toStringAsFixed(0)} km  Size: ${e.issAngularSizeArcsec.toStringAsFixed(2)}\"  Dur: ${e.durationSeconds.toStringAsFixed(2)} s  Kind: ${e.kind}'
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
