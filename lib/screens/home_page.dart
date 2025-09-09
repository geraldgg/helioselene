import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import '../core/ffi.dart';
import '../models/transit.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Transit> _events = [];
  bool _busy = false;
  String? _error;

  Future<List<String>> _fetchISSTLE() async {
    final url = Uri.parse('https://celestrak.org/NORAD/elements/stations.txt');
    final response = await http.get(url);
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch TLEs: HTTP ${response.statusCode}');
    }
    final lines = response.body.split('\n');
    for (int i = 0; i < lines.length - 2; i++) {
      if (lines[i].trim().toUpperCase().contains('ISS')) {
        final tle1 = lines[i + 1].trim();
        final tle2 = lines[i + 2].trim();
        if (tle1.startsWith('1 ') && tle2.startsWith('2 ')) {
          return [tle1, tle2];
        }
      }
    }
    throw Exception('ISS TLE not found in Celestrak data');
  }

  Future<void> _runPrediction() async {
    setState(() { _busy = true; _error = null; _events = []; });
    try {
      // TODO: replace with actual location (use geolocator plugin). For now, Paris.
      final tleLines = await _fetchISSTLE();
      final tle1 = tleLines[0];
      final tle2 = tleLines[1];
      final now = DateTime.now().toUtc();
      final events = NativeCore.predictTransits(
        tle1: tle1,
        tle2: tle2,
        lat: 48.8566, lon: 2.3522, altM: 35,
        startUtc: now,
        endUtc: now.add(const Duration(days: 14)),
      );
      setState(() { _events = events; });
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
      appBar: AppBar(title: const Text('ISS Transit Finder')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
                ? const Center(child: Text('No events yet. Tap Predict.'))
                : ListView.separated(
                    itemCount: _events.length,
                    separatorBuilder: (_, __) => const Divider(),
                    itemBuilder: (context, i) {
                      final e = _events[i];
                      return ListTile(
                        leading: Icon(e.body == 'Sun' ? Icons.wb_sunny : Icons.nightlight_round),
                        title: Text('${e.body} — ${e.kind}'),
                        subtitle: Text(
                          'When: ${dateFmt.format(e.timeUtc)}\n'
                          'Min separation: ${e.minSeparationArcsec.toStringAsFixed(1)}″\n'
                          'Duration: ${e.durationSeconds.toStringAsFixed(2)} s\n'
                          'Alt: ${e.bodyAltitudeDeg.toStringAsFixed(1)}°   Range: ${e.issRangeKm.toStringAsFixed(0)} km\n'
                          'ISS ang. size: ${e.issAngularSizeArcsec.toStringAsFixed(1)}″'
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
