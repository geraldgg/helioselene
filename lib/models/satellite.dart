class Satellite {
  final String name;
  final int noradId;
  final String tleUrl;
  bool selected;

  Satellite({
    required this.name,
    required this.noradId,
    required this.tleUrl,
    this.selected = true,
  });

  static List<Satellite> get supportedSatellites => [
    Satellite(
      name: 'ISS (ZARYA)',
      noradId: 25544,
      tleUrl: 'https://celestrak.org/NORAD/elements/gp.php?CATNR=25544&FORMAT=TLE',
    ),
    Satellite(
      name: 'TIANGONG',
      noradId: 48274,
      tleUrl: 'https://celestrak.org/NORAD/elements/gp.php?CATNR=48274&FORMAT=TLE',
    ),
    Satellite(
      name: 'HUBBLE SPACE TELESCOPE',
      noradId: 20580,
      tleUrl: 'https://celestrak.org/NORAD/elements/gp.php?CATNR=20580&FORMAT=TLE',
    ),
  ];
}

