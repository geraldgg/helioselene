import 'package:flutter_test/flutter_test.dart';
import 'package:helioselene/models/transit.dart';

void main() {
  group('Transit.fromJson', () {
    test('parses current native JSON payload', () {
      final json = {
        'time_utc': '2025-10-10T06:43:45Z',
        'body': 'Sun',
        'separation_arcmin': 4.87,
        'target_radius_arcmin': 16.0,
        'kind': 'transit',
        'sat_alt_deg': 5.7,
        'sat_az_deg': 107.1,
        'target_alt_deg': 14.3,
        'satellite': 'ISS (ZARYA)',
        'speed_deg_per_s': 0.28,
        'speed_arcmin_per_s': 16.8,
        'velocity_alt_deg_per_s': 0.05,
        'velocity_az_deg_per_s': 0.12,
        'motion_direction_deg': 135.0,
        'duration_s': 1.9,
        'sat_angular_size_arcsec': 54.2,
        'sat_distance_km': 810.0,
      };

      final transit = Transit.fromJson(json);

      expect(transit.timeUtc.toIso8601String(), '2025-10-10T06:43:45.000Z');
      expect(transit.body, 'Sun');
      expect(transit.kind, 'Transit'); // capitalized form
      expect(transit.minSeparationArcmin, closeTo(4.87, 1e-6));
      expect(transit.targetRadiusArcmin, closeTo(16.0, 1e-6));
      expect(transit.speedArcminPerS, closeTo(16.8, 1e-6));
      expect(transit.motionDirectionDeg, closeTo(135.0, 1e-6));
    });

    test('supports legacy epoch and arcsecond fields', () {
      final epochSeconds = DateTime.utc(2025, 10, 7, 15, 23, 45)
          .millisecondsSinceEpoch ~/ 1000;
      final json = {
        't_center_epoch': epochSeconds,
        'body': 'moon',
        'min_sep_arcsec': 120.0,
        'target_radius_arcmin': 14.8,
        'kind': 'near',
        'sat_alt_deg': 22.0,
        'sat_az_deg': 195.0,
        'target_alt_deg': 18.0,
        'satellite': 'TIANGONG',
        'speed_deg_per_s': 0.15,
        'durationSeconds': 0.8,
        'sat_ang_size_arcsec': 24.0,
        'sat_distance_km': 920.0,
      };

      final transit = Transit.fromJson(json);

      expect(transit.timeUtc.toIso8601String(), '2025-10-07T15:23:45.000Z');
      // 120 arcsec => 2 arcmin
      expect(transit.minSeparationArcmin, closeTo(2.0, 1e-6));
      expect(transit.kind, 'Near'); // normalized casing
      // speedArcminPerS computed when missing (deg * 60)
      expect(transit.speedArcminPerS, closeTo(9.0, 1e-6));
      expect(transit.issAngularSizeArcsec, closeTo(24.0, 1e-6));
    });
  });

  group('Transit.copyWith', () {
    test('overrides selected fields without mutating original', () {
      final original = Transit(
        timeUtc: DateTime.utc(2025, 10, 6, 16, 19, 14),
        body: 'Sun',
        kind: 'Reachable',
        minSeparationArcmin: 63.3,
        durationSeconds: 0.0,
        bodyAltitudeDeg: 9.6,
        issRangeKm: 1517.8,
        issAngularSizeArcsec: 8.6,
        satAzDeg: 251.6,
        satellite: 'ISS (ZARYA)',
        targetRadiusArcmin: 16.0,
        satAltitudeDeg: 9.6,
        speedDegPerS: 0.22,
        speedArcminPerS: 13.2,
        velocityAltDegPerS: -0.03,
        velocityAzDegPerS: 0.18,
        motionDirectionDeg: 239.0,
      );

      final updated = original.copyWith(
        kind: 'Transit',
        minSeparationArcmin: 0.5,
      );

      expect(updated.kind, 'Transit');
      expect(updated.minSeparationArcmin, closeTo(0.5, 1e-6));
      expect(updated.timeUtc, original.timeUtc);
      expect(original.kind, 'Reachable'); // unchanged
    });
  });
}
