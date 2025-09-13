class Transit {
  final DateTime timeUtc;
  final String body; // 'Sun' or 'Moon'
  final String kind; // 'Transit' or 'Near'
  final double minSeparationArcsec;
  final double durationSeconds;
  final double bodyAltitudeDeg;
  final double issRangeKm;
  final double issAngularSizeArcsec;
  final String? satellite; // Optional satellite name (ISS, Tiangong, etc.)

  Transit({
    required this.timeUtc,
    required this.body,
    required this.kind,
    required this.minSeparationArcsec,
    required this.durationSeconds,
    required this.bodyAltitudeDeg,
    required this.issRangeKm,
    required this.issAngularSizeArcsec,
    this.satellite,
  });

  static Transit fromJson(Map<String, dynamic> j) {
    return Transit(
      timeUtc: DateTime.fromMillisecondsSinceEpoch(((j['t_center_epoch'] ?? 0) * 1000).toInt(), isUtc: true),
      body: j['body'] ?? 'Sun',
      kind: j['kind'] ?? 'Near',
      minSeparationArcsec: (j['min_sep_arcsec'] ?? 0).toDouble(),
      durationSeconds: (j['duration_s'] ?? 0).toDouble(),
      bodyAltitudeDeg: (j['body_alt_deg'] ?? 0).toDouble(),
      issRangeKm: (j['sat_range_km'] ?? j['iss_range_km'] ?? 0).toDouble(),
      issAngularSizeArcsec: (j['sat_ang_size_arcsec'] ?? j['iss_ang_size_arcsec'] ?? 0).toDouble(),
      satellite: j['satellite'] as String?,
    );
  }

  Transit copyWith({
    DateTime? timeUtc,
    String? body,
    String? kind,
    double? minSeparationArcsec,
    double? durationSeconds,
    double? bodyAltitudeDeg,
    double? issRangeKm,
    double? issAngularSizeArcsec,
    String? satellite,
  }) {
    return Transit(
      timeUtc: timeUtc ?? this.timeUtc,
      body: body ?? this.body,
      kind: kind ?? this.kind,
      minSeparationArcsec: minSeparationArcsec ?? this.minSeparationArcsec,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      bodyAltitudeDeg: bodyAltitudeDeg ?? this.bodyAltitudeDeg,
      issRangeKm: issRangeKm ?? this.issRangeKm,
      issAngularSizeArcsec: issAngularSizeArcsec ?? this.issAngularSizeArcsec,
      satellite: satellite ?? this.satellite,
    );
  }
}
