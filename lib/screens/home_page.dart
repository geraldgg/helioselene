import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
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
  double _nearArcmin = 10.0;

  Future<void> _runPrediction() async {
    setState(() { _busy = true; _error = null; _events = []; });
    try {
      if (_satellites.where((s) => s.selected).isEmpty) {
        setState(() { _error = 'Select at least one satellite.'; });
        return;
      }
      final DateTime startUtc = DateTime.utc(2025, 9, 13, 20, 0, 0); // fixed window for now
      final DateTime endUtc = startUtc.add(const Duration(days: 14));
      final results = await NativeCore.predictTransitsForSatellites(
        satellites: _satellites,
        lat: 48.786839,
        lon: 2.49813,
        altM: 36,
        startUtc: startUtc,
        endUtc: endUtc,
        nearArcmin: _nearArcmin,
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
      appBar: AppBar(title: const Text('Transit Finder')),
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
                        const Text('Near margin (arcmin):'),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Slider(
                            value: _nearArcmin,
                            min: 1,
                            max: 60,
                            divisions: 59,
                            label: _nearArcmin.toStringAsFixed(0),
                            onChanged: _busy ? null : (v) => setState(()=> _nearArcmin = v),
                          ),
                        ),
                        SizedBox(
                          width: 48,
                          child: Text(_nearArcmin.toStringAsFixed(0), textAlign: TextAlign.end),
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
                            'Min separation: ${e.minSeparationArcsec.toStringAsFixed(1)}″  Duration: ${e.durationSeconds.toStringAsFixed(2)} s\n'
                            'Alt: ${e.bodyAltitudeDeg.toStringAsFixed(1)}°  Range: ${e.issRangeKm.toStringAsFixed(0)} km  Size: ${e.issAngularSizeArcsec.toStringAsFixed(1)}″'
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
