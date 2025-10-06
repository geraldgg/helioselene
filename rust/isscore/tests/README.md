# Test Organization

This directory contains **integration tests** for the `isscore` library, which handles ISS solar/lunar transit predictions.

## Test Structure

### Unit Tests (`src/lib.rs`)
Located in the `src/lib.rs` file with `#[cfg(test)]` modules. These test **private functions** that are not exposed through the public API:

- ✅ `test_vector3_operations` - Vector math (add, sub, dot, cross, normalize)
- ✅ `test_observer_ecef_position` - Geodetic to ECEF coordinate transformation
- ✅ `test_ecef_to_sez` - ECEF to SEZ (South-East-Zenith) transformation
- ✅ `test_datetime_to_jd` - DateTime to Julian Date conversion
- ✅ `test_gmst` - Greenwich Mean Sidereal Time calculation
- ✅ `test_sun_position` - Sun position in ECI frame
- ✅ `test_moon_position` - Moon position in ECI frame
- ✅ `test_teme_to_ecef` - TEME to ECEF coordinate transformation
- ✅ `test_sgp4_propagation` - SGP4 orbital propagation with ISS TLE
- ✅ `test_altaz_conversion` - Altitude/Azimuth calculation
- ✅ `test_angular_radius` - Angular radius calculation for celestial bodies
- ✅ `test_separation_calculation` - Angular separation between directions
- ✅ `test_calculate_transit_duration` - Transit duration based on angular velocity

**Total: 13 unit tests**

### Integration Tests (`tests/integration_tests.rs`)
Located in this directory. These test the **public FFI API** that external callers (like Dart/Flutter) use:

- ✅ `test_predict_transits_paris` - Full prediction workflow for Paris location
- ✅ `test_predict_transits_north_pole` - Edge case testing (extreme latitude)
- ✅ `test_predict_transits_equator` - Equator location testing
- ✅ `test_predict_transits_short_window` - 1-hour time window
- ✅ `test_predict_transits_long_window` - 7-day time window with multiple events

**Total: 5 integration tests**

## Running Tests

```powershell
# Run all tests (unit + integration)
cargo test

# Run only unit tests
cargo test --lib

# Run only integration tests
cargo test --test integration_tests

# Run with output visible
cargo test -- --nocapture

# Run a specific test
cargo test test_predict_transits_paris -- --nocapture
```

## Test Coverage

The tests validate:

1. **Coordinate Transformations**
   - Geodetic ↔ ECEF
   - TEME ↔ ECEF
   - ECEF ↔ SEZ (local topocentric)
   - Altitude/Azimuth calculations

2. **Time Conversions**
   - DateTime → Julian Date
   - GMST calculation

3. **Celestial Mechanics**
   - Sun position (ECI frame)
   - Moon position (ECI frame)
   - Angular separations
   - Angular sizes/radii

4. **Satellite Propagation**
   - SGP4 propagator with real ISS TLE
   - Position/velocity calculations

5. **Transit Calculations**
   - Transit duration estimation
   - Event detection (transit vs reachable)
   - Multiple time windows
   - Edge cases (extreme latitudes, short/long windows)

6. **FFI Interface**
   - JSON serialization/deserialization
   - Memory management (free_json)
   - Error handling
   - Multi-event scenarios

## Event Types

The library returns JSON with the following event types:

- **`transit`** - ISS passes directly in front of Sun/Moon
- **`reachable`** - ISS is close enough to potentially transit (within ~1.4× target radius)

Each event includes:
- Time, location (alt/az), angular separation
- Target body (Sun/Moon) and its angular size
- Satellite angular size and distance
- Motion vector (speed, direction)
- Duration estimate

## Python Comparison

For cross-language validation, compare with:
- `test/compare_rust_python.py` - Compares Rust FFI output with Python Skyfield
- `test/simple_ffi_test.py` - Basic FFI smoke test

## Notes

- Tests use real ISS TLE data from October 2025
- Times are in Unix epoch (seconds since 1970-01-01)
- All angles in degrees unless specified (some internal calculations use radians)
- Coordinate frames: TEME (SGP4 native), ECEF (Earth-fixed), ECI (inertial)
