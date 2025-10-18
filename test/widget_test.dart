import 'package:flutter_test/flutter_test.dart';
import 'package:helioselene/models/transit.dart';
import 'package:helioselene/widgets/transit_visual.dart';

Transit _buildTransit({
  required double minSeparationArcmin,
  required double targetRadiusArcmin,
}) {
  return Transit(
    timeUtc: DateTime.utc(2025, 10, 10, 6, 43, 45),
    body: 'Sun',
    kind: 'Transit',
    minSeparationArcmin: minSeparationArcmin,
    durationSeconds: 1.8,
    bodyAltitudeDeg: 15.0,
    issRangeKm: 800,
    issAngularSizeArcsec: 54,
    satAzDeg: 120,
    satellite: 'ISS',
    targetRadiusArcmin: targetRadiusArcmin,
    satAltitudeDeg: 45,
    speedDegPerS: 0.25,
    speedArcminPerS: 0.25 * 60,
    velocityAltDegPerS: 0.05,
    velocityAzDegPerS: 0.12,
    motionDirectionDeg: 135,
  );
}

void main() {
  group('ChordInfo.fromTransit', () {
    test('returns transit chord when separation inside disc', () {
      final transit = _buildTransit(
        minSeparationArcmin: 4.0,
        targetRadiusArcmin: 16.0,
      );

      final chord = ChordInfo.fromTransit(transit);

      expect(chord.isTransit, isTrue);
      expect(chord.offsetArcmin, closeTo(4.0, 1e-6));
      // Chord = 2 * sqrt(r^2 - d^2) with r=16, d=4 -> ~30.983
      expect(chord.chordArcmin, closeTo(30.983866, 1e-6));
    });

    test('marks near-miss when separation exceeds target radius', () {
      final transit = _buildTransit(
        minSeparationArcmin: 25.0,
        targetRadiusArcmin: 16.0,
      );

      final chord = ChordInfo.fromTransit(transit);

      expect(chord.isTransit, isFalse);
      expect(chord.chordArcmin, equals(0));
      expect(chord.offsetArcmin, equals(25.0));
    });

    test('returns zero chord when radius is invalid', () {
      final transit = _buildTransit(
        minSeparationArcmin: 5.0,
        targetRadiusArcmin: 0.0,
      );

      final chord = ChordInfo.fromTransit(transit);

      expect(chord.isTransit, isFalse);
      expect(chord.chordArcmin, equals(0));
      expect(chord.offsetArcmin, equals(0));
    });
  });
}
