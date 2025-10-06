class Transit {
  final DateTime timeUtc;
  final String body; // 'Sun' or 'Moon'
  final String kind; // 'Transit' or 'Near'
  final double minSeparationArcmin; // only arcminutes retained
  final double durationSeconds;
  final double bodyAltitudeDeg;
  final double issRangeKm;
  final double issAngularSizeArcsec;
  final double satAzDeg; // new azimuth
  final String? satellite; // Optional satellite name (ISS, Tiangong, etc.)
  final double targetRadiusArcmin; // new
  final double satAltitudeDeg; // new (sat_alt_deg)
  final double speedDegPerS; // new
  final double speedArcminPerS; // new
  final double velocityAltDegPerS; // newly added
  final double velocityAzDegPerS;  // newly added
  final double motionDirectionDeg; // newly added (direction of motion projection)

  Transit({
    required this.timeUtc,
    required this.body,
    required this.kind,
    required this.minSeparationArcmin,
    required this.durationSeconds,
    required this.bodyAltitudeDeg,
    required this.issRangeKm,
    required this.issAngularSizeArcsec,
    required this.satAzDeg,
    this.satellite,
    required this.targetRadiusArcmin,
    required this.satAltitudeDeg,
    required this.speedDegPerS,
    required this.speedArcminPerS,
    this.velocityAltDegPerS = 0.0,
    this.velocityAzDegPerS = 0.0,
    this.motionDirectionDeg = 0.0,
  });

  static Transit fromJson(Map<String, dynamic> j) {
    // --- Time parsing ---
    DateTime timeUtc;
    if (j.containsKey('t_center_epoch')) {
      // Epoch seconds coming from earlier/native versions
      final secs = (j['t_center_epoch'] ?? 0);
      timeUtc = DateTime.fromMillisecondsSinceEpoch((secs is num ? secs.toInt() : 0) * 1000, isUtc: true);
    } else if (j.containsKey('time_utc')) {
      // ISO-8601 string provided by current Rust library
      final raw = j['time_utc']?.toString() ?? '';
      try {
        timeUtc = DateTime.parse(raw).toUtc();
      } catch (_) {
        timeUtc = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      }
    } else {
      timeUtc = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }

    // --- Separation (arcminutes) ---
    double arcmin;
    if (j.containsKey('separation_arcmin')) {
      arcmin = (j['separation_arcmin'] as num).toDouble();
    } else if (j.containsKey('min_sep_arcmin')) {
      arcmin = (j['min_sep_arcmin'] as num).toDouble();
    } else if (j.containsKey('min_sep_arcsec')) {
      arcmin = (j['min_sep_arcsec'] as num).toDouble() / 60.0;
    } else if (j.containsKey('minSeparationArcsec')) {
      arcmin = (j['minSeparationArcsec'] as num).toDouble() / 60.0;
    } else {
      arcmin = 0.0;
    }

    // --- Kind normalization ---
    String rawKind = (j['kind'] ?? 'Near').toString();
    switch (rawKind.toLowerCase()) {
      case 'transit': rawKind = 'Transit'; break;
      case 'near': rawKind = 'Near'; break;
      case 'reachable': rawKind = 'Reachable'; break;
      default: break;
    }

    // --- Field extraction with fallbacks matching Rust JSON ---
    final durationSeconds = (j['duration_s'] ?? j['durationSeconds'] ?? 0).toDouble();
    final bodyAltitudeDeg = (j['target_alt_deg'] ?? j['body_alt_deg'] ?? j['bodyAltitudeDeg'] ?? 0).toDouble();
    final satAltitudeDeg = (j['iss_alt_deg'] ?? j['sat_alt_deg'] ?? j['satAltitudeDeg'] ?? 0).toDouble();
    final issRangeKm = (j['sat_distance_km'] ?? j['sat_range_km'] ?? j['iss_range_km'] ?? j['issRangeKm'] ?? 0).toDouble();
    final issAngularSizeArcsec = (j['sat_angular_size_arcsec'] ?? j['sat_ang_size_arcsec'] ?? j['iss_ang_size_arcsec'] ?? j['issAngularSizeArcsec'] ?? 0).toDouble();
    final satAzDeg = (j['sat_az_deg'] ?? j['satAzDeg'] ?? 0).toDouble();
    final targetRadiusArcmin = (j['target_radius_arcmin'] ?? j['targetRadiusArcmin'] ?? 0).toDouble();
    final speedDegPerS = (j['speed_deg_per_s'] ?? j['speedDegPerS'] ?? 0).toDouble();
    final speedArcminPerS = (j['speed_arcmin_per_s'] ?? j['speedArcminPerS'] ?? (speedDegPerS * 60.0)).toDouble();
    final velocityAltDegPerS = (j['velocity_alt_deg_per_s'] ?? j['velocityAltDegPerS'] ?? 0).toDouble();
    final velocityAzDegPerS = (j['velocity_az_deg_per_s'] ?? j['velocityAzDegPerS'] ?? 0).toDouble();
    final motionDirectionDeg = (j['motion_direction_deg'] ?? j['motionDirectionDeg'] ?? 0).toDouble();

    return Transit(
      timeUtc: timeUtc,
      body: j['body'] ?? 'Sun',
      kind: rawKind,
      minSeparationArcmin: arcmin,
      durationSeconds: durationSeconds,
      bodyAltitudeDeg: bodyAltitudeDeg,
      issRangeKm: issRangeKm,
      issAngularSizeArcsec: issAngularSizeArcsec,
      satAzDeg: satAzDeg,
      satellite: j['satellite'] as String?,
      targetRadiusArcmin: targetRadiusArcmin,
      satAltitudeDeg: satAltitudeDeg,
      speedDegPerS: speedDegPerS,
      speedArcminPerS: speedArcminPerS,
      velocityAltDegPerS: velocityAltDegPerS,
      velocityAzDegPerS: velocityAzDegPerS,
      motionDirectionDeg: motionDirectionDeg,
    );
  }

  Transit copyWith({
    DateTime? timeUtc,
    String? body,
    String? kind,
    double? minSeparationArcmin,
    double? durationSeconds,
    double? bodyAltitudeDeg,
    double? issRangeKm,
    double? issAngularSizeArcsec,
    double? satAzDeg,
    String? satellite,
    double? targetRadiusArcmin,
    double? satAltitudeDeg,
    double? speedDegPerS,
    double? speedArcminPerS,
    double? velocityAltDegPerS,
    double? velocityAzDegPerS,
    double? motionDirectionDeg,
  }) {
    return Transit(
      timeUtc: timeUtc ?? this.timeUtc,
      body: body ?? this.body,
      kind: kind ?? this.kind,
      minSeparationArcmin: minSeparationArcmin ?? this.minSeparationArcmin,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      bodyAltitudeDeg: bodyAltitudeDeg ?? this.bodyAltitudeDeg,
      issRangeKm: issRangeKm ?? this.issRangeKm,
      issAngularSizeArcsec: issAngularSizeArcsec ?? this.issAngularSizeArcsec,
      satAzDeg: satAzDeg ?? this.satAzDeg,
      targetRadiusArcmin: targetRadiusArcmin ?? this.targetRadiusArcmin,
      satAltitudeDeg: satAltitudeDeg ?? this.satAltitudeDeg,
      speedDegPerS: speedDegPerS ?? this.speedDegPerS,
      speedArcminPerS: speedArcminPerS ?? this.speedArcminPerS,
      velocityAltDegPerS: velocityAltDegPerS ?? this.velocityAltDegPerS,
      velocityAzDegPerS: velocityAzDegPerS ?? this.velocityAzDegPerS,
      motionDirectionDeg: motionDirectionDeg ?? this.motionDirectionDeg,
      satellite: satellite ?? this.satellite,
    );
  }
}
