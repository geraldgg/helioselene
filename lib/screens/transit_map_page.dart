import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../models/transit.dart';
import '../core/shared_tile_provider.dart';
import 'package:flutter/services.dart';
import 'dart:convert';

/// Page displaying an approximate ground visibility region for the selected transit.
/// NOTE: This is an approximation: we model the area in which moving could turn a near/reachable
/// event into a full transit as a circle around the observer. Precise central line & parallax
/// corridor would require additional geometry not yet exposed by the native library.
class TransitMapPage extends StatefulWidget {
  final Transit transit;
  final double observerLat;
  final double observerLon;
  const TransitMapPage({super.key, required this.transit, required this.observerLat, required this.observerLon});

  @override
  State<TransitMapPage> createState() => _TransitMapPageState();
}

class _TransitMapPageState extends State<TransitMapPage> {
  late final MapController _mapController;

  Map<String, String> _i18n = {};
  Locale? _i18nLocale;
  bool _loadingI18n = false;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final locale = Localizations.localeOf(context);
    if (_i18nLocale != locale) {
      _loadTranslations(locale);
    }
  }

  Future<void> _loadTranslations(Locale locale) async {
    if (_loadingI18n) return;
    _loadingI18n = true;
    try {
      final jsonString = await rootBundle.loadString('assets/l10n/${locale.languageCode}.json');
      final Map<String, dynamic> jsonMap = json.decode(jsonString);
      if (mounted) {
        setState(() {
          _i18n = jsonMap.map((k, v) => MapEntry(k, v.toString()));
          _i18nLocale = locale;
        });
      } else {
        _i18n = jsonMap.map((k, v) => MapEntry(k, v.toString()));
        _i18nLocale = locale;
      }
    } catch (_) {
      // silent fail; keys used
    } finally {
      _loadingI18n = false;
    }
  }

  String tr(String key) => _i18n[key] ?? key;
  String _kindLabel(String kind) {
    switch (kind.toLowerCase()) {
      case 'transit': return tr('kindTransit');
      case 'reachable': return tr('kindReachable');
      case 'near':
      default: return tr('kindNear');
    }
  }
  String _bodyLabel(String body) {
    switch (body.toLowerCase()) {
      case 'sun': return tr('bodySun');
      case 'moon': return tr('bodyMoon');
      default: return body;
    }
  }

  double _targetRadiusGroundKm() {
    // target angular radius (arcmin) -> radians
    final targetRadiusDeg = widget.transit.targetRadiusArcmin / 60.0;
    final targetRadiusRad = targetRadiusDeg * math.pi / 180.0;
    final satRangeKm = widget.transit.issRangeKm;
    if (satRangeKm <= 0 || targetRadiusRad <= 0) return 0;
    return satRangeKm * targetRadiusRad; // small angle arc length
  }

  /// Minimum lateral ground shift needed to reach centerline (approx) if not a transit.
  double _requiredShiftKm() {
    final satRangeKm = widget.transit.issRangeKm;
    if (satRangeKm <= 0) return 0;
    final minSepDeg = widget.transit.minSeparationArcmin / 60.0; // degrees
    final tgtDeg = widget.transit.targetRadiusArcmin / 60.0;
    final excessDeg = math.max(0.0, minSepDeg - tgtDeg);
    if (excessDeg <= 0) return 0;
    final excessRad = excessDeg * math.pi / 180.0;
    return satRangeKm * excessRad; // arc length ~ lateral displacement
  }

  double _outerRadiusKm() {
    // Outer radius depicts: required shift (if any) + transit corridor half-width (target radius)
    final base = _requiredShiftKm();
    final corridor = _targetRadiusGroundKm();
    if (corridor <= 0) return math.max(1, base); // fallback
    // Add some safety padding (25%)
    return base + corridor * 1.25;
  }

  double _innerRadiusKm() {
    // Inner circle: current location guaranteed transit region (approx corridor width)
    final corridor = _targetRadiusGroundKm();
    if (widget.transit.kind.toLowerCase() == 'transit') {
      return math.max(0.25, corridor); // transit at current spot
    } else {
      // For near/reachable, show just the corridor width (indicates precision needed there)
      return corridor;
    }
  }

  double _suggestedZoom(double radiusKm) {
    // Crude heuristic to choose an initial zoom
    if (radiusKm <= 2) return 13.0;
    if (radiusKm <= 5) return 12.0;
    if (radiusKm <= 15) return 11.0;
    if (radiusKm <= 40) return 9.5;
    if (radiusKm <= 120) return 8.0;
    if (radiusKm <= 300) return 7.0;
    return 5.5;
  }

  // Helper function to compute look direction point
  LatLng _lookDirectionPoint(LatLng origin, double azimuthDeg, double distanceKm) {
    // Move from origin in azimuth direction by distanceKm
    final distance = Distance();
    return distance.offset(origin, distanceKm * 1000, azimuthDeg);
  }

  @override
  Widget build(BuildContext context) {
    final center = LatLng(widget.observerLat, widget.observerLon);
    final outerRadiusKm = _outerRadiusKm();
    final innerRadiusKm = _innerRadiusKm();
    final zoom = _suggestedZoom(outerRadiusKm);
    final arrowDistanceKm = 1.4; // shorter than previous 2.0 for cleaner look

    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(tr('visibilityMapTitle'))),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final maxPanelHeight = size.height * 0.34; // limit bottom panel to ~1/3 screen
          return Stack(
            children: [
              // Map fills available space
              Positioned.fill(
                child: Hero(
                  tag: 'map-${widget.transit.timeUtc.toIso8601String()}',
                  child: FlutterMap(
                    key: const ValueKey('transit-full-map-hero'),
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: center,
                      initialZoom: zoom,
                      interactionOptions: const InteractionOptions(
                        flags: ~InteractiveFlag.rotate,
                      ),
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'helioselene',
                        tileProvider: SharedTileProvider.osm,
                      ),
                      CircleLayer(circles: [
                        if (outerRadiusKm > 0)
                          CircleMarker(
                            point: center,
                            radius: outerRadiusKm * 1000,
                            useRadiusInMeter: true,
                            color: Colors.orangeAccent.withValues(alpha: 0.18),
                            borderColor: Colors.orangeAccent.withValues(alpha: 0.5),
                            borderStrokeWidth: 2,
                          ),
                        if (innerRadiusKm > 0)
                          CircleMarker(
                            point: center,
                            radius: innerRadiusKm * 1000,
                            useRadiusInMeter: true,
                            color: Colors.lightBlueAccent.withValues(alpha: 0.20),
                            borderColor: Colors.lightBlueAccent.withValues(alpha: 0.6),
                            borderStrokeWidth: 2,
                          ),
                      ]),
                      // Draw polyline before markers so line visually starts beneath marker icons
                      PolylineLayer(polylines: [
                        Polyline(
                          points: [center, _lookDirectionPoint(center, widget.transit.satAzDeg, arrowDistanceKm)], // extend to 2km for clearer direction
                          color: Colors.redAccent,
                          strokeWidth: 3,
                        ),
                      ]),
                      MarkerLayer(markers: [
                        // User location marker (simplified so the coordinate is at icon center)
                        Marker(
                          point: center,
                          width: 40,
                          height: 40,
                          alignment: Alignment.center,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: theme.colorScheme.primary.withValues(alpha: 0.14),
                              border: Border.all(color: theme.colorScheme.primary, width: 2),
                            ),
                            child: Icon(Icons.my_location, color: theme.colorScheme.primary, size: 18),
                          ),
                        ),
                        // Look direction marker
                        Marker(
                          point: _lookDirectionPoint(center, widget.transit.satAzDeg, arrowDistanceKm), // matches polyline end
                          width: 46,
                          height: 46,
                          alignment: Alignment.center,
                          child: Transform.rotate(
                            angle: widget.transit.satAzDeg * math.pi / 180.0,
                            child: const Icon(
                              Icons.navigation,
                              size: 30, // smaller arrow
                              color: Colors.redAccent,
                            ),
                          ),
                        ),
                      ]),
                    ],
                  ),
                ),
              ),
              // Recenter button
              Positioned(
                top: 12,
                right: 12,
                child: FloatingActionButton(
                  heroTag: 'recenter-${widget.transit.timeUtc.toIso8601String()}',
                  mini: true,
                  onPressed: () {
                    _mapController.move(center, zoom);
                  },
                  child: const Icon(Icons.my_location),
                ),
              ),
              // Bottom information panel (scrollable, constrained height)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SafeArea(
                  top: false,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut,
                    constraints: BoxConstraints(maxHeight: maxPanelHeight),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.78),
                      border: Border(top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.4))),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.25),
                          blurRadius: 8,
                          offset: const Offset(0, -2),
                        ),
                      ],
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(16),
                        topRight: Radius.circular(16),
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(16),
                        topRight: Radius.circular(16),
                      ),
                      child: DefaultTextStyle(
                        style: theme.textTheme.bodySmall!,
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.info_outline, size: 16, color: theme.colorScheme.primary),
                                  const SizedBox(width: 6),
                                  Text('${_bodyLabel(widget.transit.body)} - ${_kindLabel(widget.transit.kind)}', style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600)),
                                  const Spacer(),
                                  // Small legend dot for user position label moved off map
                                  Row(
                                    children: [
                                      Container(
                                        width: 10,
                                        height: 10,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: theme.colorScheme.primary,
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(tr('youLabel'), style: theme.textTheme.labelSmall),
                                      const SizedBox(width: 12),
                                      Container(
                                        width: 10,
                                        height: 10,
                                        decoration: const BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: Colors.redAccent,
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(tr('directionLabel'), style: theme.textTheme.labelSmall?.copyWith(color: Colors.redAccent)),
                                    ],
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text('${tr('eventTimeLabel')}: ${widget.transit.timeUtc.toLocal()}'),
                              Text('${tr('satelliteRangeLabel')}: ${widget.transit.issRangeKm.toStringAsFixed(0)} km'),
                              if (innerRadiusKm > 0)
                                Text('${tr('corridorWidthLabel')}: ${innerRadiusKm.toStringAsFixed(2)} km'),
                              if (outerRadiusKm > 0)
                                Text('${tr('reachZoneLabel')}: ${outerRadiusKm.toStringAsFixed(2)} km'),
                              if (widget.transit.kind.toLowerCase() != 'transit') ...[
                                const SizedBox(height: 6),
                                Text(tr('tipLabel')),
                              ],
                              const SizedBox(height: 8),
                              Text(
                                '${tr('directionToLookLabel')}: ${widget.transit.satAzDeg.toStringAsFixed(1)}°',
                                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.secondary),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                tr('approxNoteLabel'),
                                style: theme.textTheme.bodySmall?.copyWith(fontSize: (theme.textTheme.bodySmall?.fontSize ?? 12) - 1, color: theme.colorScheme.onSurface.withValues(alpha: 0.65)),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
