// lib.rs - ISS Transit Prediction Library for Flutter/FFI
// Rewritten using proven main.rs algorithm (direct scanning without pass pre-filtering)

use std::ffi::{CStr, CString, c_char};
use std::f64::consts::PI;
use serde::Serialize;
use chrono::{DateTime, Datelike, Duration, Timelike, Utc};
use log::{info, warn};
use std::sync::Once;

// ============================================================================
// Constants (from main.rs)
// ============================================================================

const SUN_RADIUS_KM: f64 = 696_340.0;
const MOON_RADIUS_KM: f64 = 1_737.4;
const AU_KM: f64 = 149_597_870.7;
const ISS_DIMENSION_M: f64 = 108.0;
const EARTH_RADIUS_KM: f64 = 6378.137; // WGS-84
const EARTH_FLATTENING: f64 = 1.0 / 298.257_223_563;
const EARTH_E2: f64 = EARTH_FLATTENING * (2.0 - EARTH_FLATTENING);

// ============================================================================
// Simple Vector3 (from main.rs)
// ============================================================================

#[derive(Debug, Clone, Copy)]
struct Vector3 {
    x: f64,
    y: f64,
    z: f64,
}

impl Vector3 {
    fn new(x: f64, y: f64, z: f64) -> Self {
        Self { x, y, z }
    }
    
    fn norm(&self) -> f64 {
        (self.x * self.x + self.y * self.y + self.z * self.z).sqrt()
    }
    
    fn sub(&self, other: &Vector3) -> Vector3 {
        Vector3::new(self.x - other.x, self.y - other.y, self.z - other.z)
    }
    
    fn dot(&self, other: &Vector3) -> f64 {
        self.x * other.x + self.y * other.y + self.z * other.z
    }
}

// ============================================================================
// Output Structure (same as main.rs)
// ============================================================================

#[derive(Serialize, Debug)]
#[cfg_attr(test, derive(serde::Deserialize))]  // Add Deserialize only for tests
struct Event {
    time_utc: String,
    body: String,
    separation_arcmin: f64,
    target_radius_arcmin: f64,
    kind: String,
    sat_alt_deg: f64,
    sat_az_deg: f64,
    target_alt_deg: f64,
    satellite: String,
    speed_deg_per_s: f64,
    speed_arcmin_per_s: f64,
    velocity_alt_deg_per_s: f64,
    velocity_az_deg_per_s: f64,
    motion_direction_deg: f64,
    duration_s: f64,
    sat_angular_size_arcsec: f64,
    sat_distance_km: f64,
}

// ============================================================================
// Logging Setup
// ============================================================================

static INIT_LOGGER: Once = Once::new();

#[cfg(target_os = "android")]
fn init_logger() {
    use android_logger::Config;
    use log::LevelFilter;
    INIT_LOGGER.call_once(|| {
        android_logger::init_once(
            Config::default()
                .with_max_level(LevelFilter::Info)
                .with_tag("isscore")
        );
    });
}

#[cfg(not(target_os = "android"))]
fn init_logger() {
    INIT_LOGGER.call_once(|| {
        let _ = env_logger::Builder::from_default_env()
            .filter_level(log::LevelFilter::Info)
            .try_init();
    });
}

// ============================================================================
// Time & Coordinate Utilities (from main.rs)
// ============================================================================

fn datetime_to_jd(dt: DateTime<Utc>) -> f64 {
    let y = dt.year();
    let mut m = dt.month() as i32;
    let mut y2 = y;
    if m <= 2 {
        y2 -= 1;
        m += 12;
    }
    let a = (y2 as f64 / 100.0).floor();
    let b = 2.0 - a + (a / 4.0).floor();
    let day = dt.day() as f64;
    let frac = (dt.hour() as f64 
        + dt.minute() as f64 / 60.0
        + dt.second() as f64 / 3600.0
        + dt.timestamp_subsec_micros() as f64 / 3_600_000_000.0) / 24.0;
    
    (365.25 * (y2 as f64 + 4716.0)).floor()
        + (30.6001 * (m as f64 + 1.0)).floor()
        + day + frac + b - 1524.5
}

fn gmst_rad(jd: f64) -> f64 {
    let t = (jd - 2451545.0) / 36525.0;
    let gmst_deg = 280.46061837
        + 360.98564736629 * (jd - 2451545.0)
        + 0.000387933 * t * t
        - t * t * t / 38710000.0;
    
    let mut gmst_rad = gmst_deg.to_radians();
    gmst_rad = gmst_rad % (2.0 * PI);
    if gmst_rad < 0.0 {
        gmst_rad += 2.0 * PI;
    }
    gmst_rad
}

fn rot_z(theta: f64) -> [[f64; 3]; 3] {
    let (s, c) = theta.sin_cos();
    [
        [c, -s, 0.0],
        [s,  c, 0.0],
        [0.0, 0.0, 1.0],
    ]
}

fn mat_mul_vec(m: &[[f64; 3]; 3], v: &Vector3) -> Vector3 {
    Vector3::new(
        m[0][0] * v.x + m[0][1] * v.y + m[0][2] * v.z,
        m[1][0] * v.x + m[1][1] * v.y + m[1][2] * v.z,
        m[2][0] * v.x + m[2][1] * v.y + m[2][2] * v.z,
    )
}

fn geodetic_to_ecef(lat_rad: f64, lon_rad: f64, alt_m: f64) -> Vector3 {
    let (sin_lat, cos_lat) = lat_rad.sin_cos();
    let n = EARTH_RADIUS_KM / (1.0 - EARTH_E2 * sin_lat * sin_lat).sqrt();
    let alt_km = alt_m / 1000.0;
    
    Vector3::new(
        (n + alt_km) * cos_lat * lon_rad.cos(),
        (n + alt_km) * cos_lat * lon_rad.sin(),
        (n * (1.0 - EARTH_E2) + alt_km) * sin_lat,
    )
}

fn angle_between(a: &Vector3, b: &Vector3) -> f64 {
    let dot = a.dot(b);
    let denom = a.norm() * b.norm();
    (dot / denom).clamp(-1.0, 1.0).acos()
}

// ============================================================================
// Celestial Body Positions (from main.rs)
// ============================================================================

fn sun_position_eci(jd: f64) -> Vector3 {
    let d = jd - 2451545.0;
    let l = (280.460 + 0.9856474 * d) % 360.0;
    let g = ((357.528 + 0.9856003 * d) % 360.0).to_radians();
    let lambda = (l + 1.915 * g.sin() + 0.020 * (2.0 * g).sin()).to_radians();
    let r = 1.00014 - 0.01671 * g.cos() - 0.00014 * (2.0 * g).cos();
    let epsilon = (23.439 - 0.0000004 * d).to_radians();
    
    let x = r * lambda.cos();
    let y = r * lambda.sin() * epsilon.cos();
    let z = r * lambda.sin() * epsilon.sin();
    
    Vector3::new(x * AU_KM, y * AU_KM, z * AU_KM)
}

fn moon_position_eci(jd: f64) -> Vector3 {
    let t = (jd - 2451545.0) / 36525.0;
    
    let l_prime = (218.316 + 481267.881 * t).to_radians();
    let d = (297.850 + 445267.115 * t).to_radians();
    let m = (357.529 + 35999.050 * t).to_radians();
    let m_prime = (134.963 + 477198.868 * t).to_radians();
    let f = (93.272 + 483202.018 * t).to_radians();
    
    let lambda = l_prime
        + 6.289_f64.to_radians() * m_prime.sin()
        + 1.274_f64.to_radians() * (2.0 * d - m_prime).sin()
        + 0.658_f64.to_radians() * (2.0 * d).sin()
        + 0.214_f64.to_radians() * (2.0 * m_prime).sin()
        - 0.186_f64.to_radians() * m.sin();
    
    let beta = 5.128_f64.to_radians() * f.sin()
        + 0.280_f64.to_radians() * (m_prime + f).sin();
    
    let r = 385000.0 - 20905.0 * m_prime.cos()
        - 3699.0 * (2.0 * d - m_prime).cos()
        - 2956.0 * (2.0 * d).cos()
        - 570.0 * (2.0 * m_prime).cos();
    
    let eps = (23.439291 - 0.0130042 * t).to_radians();
    let cos_beta = beta.cos();
    
    Vector3::new(
        r * cos_beta * lambda.cos(),
        r * (cos_beta * lambda.sin() * eps.cos() - beta.sin() * eps.sin()),
        r * (cos_beta * lambda.sin() * eps.sin() + beta.sin() * eps.cos()),
    )
}

fn altaz(topo_vec: &Vector3) -> (f64, f64) {
    let range = topo_vec.norm();
    let alt_rad = (topo_vec.z / range).asin();
    
    // In SEZ frame: x=South, y=East, z=Zenith
    // Azimuth from North clockwise: az = atan2(East, North) = atan2(y, -x)
    let az_rad = topo_vec.y.atan2(-topo_vec.x);
    
    // Normalize azimuth to 0-360° range
    let mut az_deg = az_rad.to_degrees();
    if az_deg < 0.0 {
        az_deg += 360.0;
    }
    
    (alt_rad.to_degrees(), az_deg)
}

// ============================================================================
// SGP4 Satellite Position (from main.rs)
// ============================================================================

fn get_sat_position(
    elements: &sgp4::Elements,
    dt: DateTime<Utc>,
) -> Result<Vector3, String> {
    let epoch = DateTime::<Utc>::from_naive_utc_and_offset(elements.datetime, Utc);
    let dt_seconds = dt.signed_duration_since(epoch).num_seconds() as f64;
    let mins = dt_seconds / 60.0;
    
    let constants = sgp4::Constants::from_elements(elements)
        .map_err(|e| format!("SGP4 constants error: {}", e))?;
    let prediction = constants.propagate(sgp4::MinutesSinceEpoch(mins))
        .map_err(|e| format!("SGP4 propagation error: {}", e))?;
    
    Ok(Vector3::new(
        prediction.position[0],
        prediction.position[1],
        prediction.position[2],
    ))
}

// ============================================================================
// Core Transit Detection (from main.rs)
// ============================================================================

fn ecef_to_sez(topo_ecef: &Vector3, lat_rad: f64, lon_rad: f64) -> Vector3 {
    let sin_lat = lat_rad.sin();
    let cos_lat = lat_rad.cos();
    let sin_lon = lon_rad.sin();
    let cos_lon = lon_rad.cos();
    
    Vector3::new(
        sin_lat * cos_lon * topo_ecef.x + sin_lat * sin_lon * topo_ecef.y - cos_lat * topo_ecef.z,
        -sin_lon * topo_ecef.x + cos_lon * topo_ecef.y,
        cos_lat * cos_lon * topo_ecef.x + cos_lat * sin_lon * topo_ecef.y + sin_lat * topo_ecef.z,
    )
}

fn compute_topo_vectors(
    elements: &sgp4::Elements,
    dt: DateTime<Utc>,
    observer_ecef: &Vector3,
    observer_lat_rad: f64,
    observer_lon_rad: f64,
    body: &str,
) -> Result<(Vector3, Vector3, f64, f64), String> {
    let sat_teme = get_sat_position(elements, dt)?;
    let jd_utc = datetime_to_jd(dt);
    let gmst = gmst_rad(jd_utc);
    let rot = rot_z(gmst);
    let observer_teme = mat_mul_vec(&rot, observer_ecef);
    let sat_topo_teme = sat_teme.sub(&observer_teme);
    
    let body_eci = match body {
        "Sun" => sun_position_eci(jd_utc),
        "Moon" => moon_position_eci(jd_utc),
        _ => return Err(format!("Unknown body: {}", body)),
    };
    
    let body_topo_teme = body_eci.sub(&observer_teme);
    let rot_inv = rot_z(-gmst);
    let sat_topo_ecef = mat_mul_vec(&rot_inv, &sat_topo_teme);
    let body_topo_ecef = mat_mul_vec(&rot_inv, &body_topo_teme);
    let sat_topo_sez = ecef_to_sez(&sat_topo_ecef, observer_lat_rad, observer_lon_rad);
    let body_topo_sez = ecef_to_sez(&body_topo_ecef, observer_lat_rad, observer_lon_rad);
    let (sat_alt, _) = altaz(&sat_topo_sez);
    let (body_alt, _) = altaz(&body_topo_sez);
    
    Ok((sat_topo_teme, body_topo_teme, sat_alt, body_alt))
}

fn refine_minimum(
    elements: &sgp4::Elements,
    t_center: DateTime<Utc>,
    observer_ecef: &Vector3,
    observer_lat_rad: f64,
    observer_lon_rad: f64,
    body: &str,
    window_s: f64,
    step_s: f64,
) -> Result<(DateTime<Utc>, f64, f64, f64, f64, f64, f64), String> {
    let n_steps = (window_s / step_s) as i64;
    let mut min_sep = f64::INFINITY;
    let mut best_time = t_center;
    let mut best_sat_alt = 0.0;
    let mut best_body_alt = 0.0;
    let mut best_sat_range = 0.0;
    
    for i in -n_steps..=n_steps {
        let t = t_center + Duration::seconds((i as f64 * step_s) as i64);
        let (sat_topo, body_topo, sat_alt, body_alt) = 
            compute_topo_vectors(elements, t, observer_ecef, observer_lat_rad, observer_lon_rad, body)?;
        let sep = angle_between(&sat_topo, &body_topo);
        
        if sep < min_sep {
            min_sep = sep;
            best_time = t;
            best_sat_alt = sat_alt;
            best_body_alt = body_alt;
            best_sat_range = sat_topo.norm();
        }
    }
    
    // Get azimuth for the best time
    let (sat_topo_best, body_topo, _, _) = compute_topo_vectors(elements, best_time, observer_ecef, observer_lat_rad, observer_lon_rad, body)?;
    let jd_best = datetime_to_jd(best_time);
    let gmst = gmst_rad(jd_best);
    let rot_inv = rot_z(-gmst);
    let sat_topo_ecef = mat_mul_vec(&rot_inv, &sat_topo_best);
    let sat_topo_sez = ecef_to_sez(&sat_topo_ecef, observer_lat_rad, observer_lon_rad);
    let (_, sat_az) = altaz(&sat_topo_sez);

    let body_distance = body_topo.norm();
    let body_radius_km = match body {
        "Sun" => SUN_RADIUS_KM,
        "Moon" => MOON_RADIUS_KM,
        _ => return Err(format!("Unknown body: {}", body)),
    };
    let body_radius_rad = (body_radius_km / body_distance).asin();
    
    Ok((
        best_time,
        min_sep.to_degrees(),
        body_radius_rad.to_degrees(),
        best_sat_alt,
        sat_az,
        best_body_alt,
        best_sat_range,
    ))
}

fn calculate_speed_and_duration(
    elements: &sgp4::Elements,
    t_min: DateTime<Utc>,
    observer_ecef: &Vector3,
    observer_lat_rad: f64,
    observer_lon_rad: f64,
    body: &str,
    step_s: f64,
) -> Result<(f64, f64, f64, f64), String> {
    let t_minus = t_min - Duration::milliseconds((step_s * 1000.0) as i64);
    let t_plus = t_min + Duration::milliseconds((step_s * 1000.0) as i64);
    
    let (sat_m, _, _, _) = compute_topo_vectors(elements, t_minus, observer_ecef, observer_lat_rad, observer_lon_rad, body)?;
    let (sat_p, _, _, _) = compute_topo_vectors(elements, t_plus, observer_ecef, observer_lat_rad, observer_lon_rad, body)?;
    
    let (alt_m, az_m) = altaz(&sat_m);
    let (alt_p, az_p) = altaz(&sat_p);
    
    // Calculate velocity components
    let velocity_alt_deg_per_s = (alt_p - alt_m) / (2.0 * step_s);
    let velocity_az_deg_per_s = (az_p - az_m) / (2.0 * step_s);
    
    // Calculate total angular speed (magnitude)
    let alt_m_rad = alt_m.to_radians();
    let az_m_rad = az_m.to_radians();
    let alt_p_rad = alt_p.to_radians();
    let az_p_rad = az_p.to_radians();
    
    let vec_m = Vector3::new(
        alt_m_rad.cos() * az_m_rad.cos(),
        alt_m_rad.cos() * az_m_rad.sin(),
        alt_m_rad.sin(),
    );
    
    let vec_p = Vector3::new(
        alt_p_rad.cos() * az_p_rad.cos(),
        alt_p_rad.cos() * az_p_rad.sin(),
        alt_p_rad.sin(),
    );
    
    let angular_dist_rad = angle_between(&vec_m, &vec_p);
    let speed_rad_per_s = angular_dist_rad / (2.0 * step_s);
    let speed_deg_per_s = speed_rad_per_s.to_degrees();
    
    // Calculate motion direction angle (0° = North, 90° = East, clockwise)
    let motion_direction_deg = velocity_az_deg_per_s.atan2(velocity_alt_deg_per_s).to_degrees();
    let motion_direction_normalized = if motion_direction_deg < 0.0 {
        motion_direction_deg + 360.0
    } else {
        motion_direction_deg
    };
    
    Ok((speed_deg_per_s, velocity_alt_deg_per_s, velocity_az_deg_per_s, motion_direction_normalized))
}

fn calculate_transit_duration(
    separation_deg: f64,
    target_radius_deg: f64,
    speed_deg_per_s: f64,
) -> f64 {
    if speed_deg_per_s <= 0.0 || separation_deg > target_radius_deg {
        return 0.0;
    }
    
    let r_sq = target_radius_deg * target_radius_deg;
    let d_sq = separation_deg * separation_deg;
    
    if d_sq >= r_sq {
        return 0.0;
    }
    
    let chord_length_deg = 2.0 * (r_sq - d_sq).sqrt();
    chord_length_deg / speed_deg_per_s
}

// ============================================================================
// Main Prediction Function (FFI)
// ============================================================================

#[no_mangle]
pub extern "C" fn predict_transits(
    tle1: *const c_char,
    tle2: *const c_char,
    lat: f64,
    lon: f64,
    alt_m: f64,
    start_epoch: i64,
    end_epoch: i64,
    max_distance_km: f64,
) -> *mut c_char {
    init_logger();
    
    info!("ISS Transit Prediction starting");
    info!("  Location: {:.5}°N, {:.5}°E, {}m", lat, lon, alt_m);
    
    let tle1_str = unsafe { CStr::from_ptr(tle1) }.to_string_lossy().into_owned();
    let tle2_str = unsafe { CStr::from_ptr(tle2) }.to_string_lossy().into_owned();
    
    let elements = match sgp4::Elements::from_tle(
        Some("ISS".to_string()),
        tle1_str.as_bytes(),
        tle2_str.as_bytes(),
    ) {
        Ok(e) => e,
        Err(e) => {
            warn!("TLE parse error: {}", e);
            return CString::new("[]").unwrap().into_raw();
        }
    };
    
    let start = DateTime::<Utc>::from_timestamp(start_epoch, 0).unwrap();
    let end = DateTime::<Utc>::from_timestamp(end_epoch, 0).unwrap();
    
    info!("  Time: {} to {}", start, end);
    info!("  Duration: {} days", (end - start).num_days());
    
    let observer_ecef = geodetic_to_ecef(lat.to_radians(), lon.to_radians(), alt_m);
    let observer_lat_rad = lat.to_radians();
    let observer_lon_rad = lon.to_radians();
    
    // Search parameters (same as main.rs defaults)
    let coarse_step_s = 20.0;
    let fine_step_s = 1.0;
    let refine_window_s = 60.0;
    let alt_min = 5.0;
    let near_margin_deg = 0.5;
    
    let mut events = Vec::new();
    let mut t = start;
    
    // DIRECT SCANNING ALGORITHM (same as main.rs)
    // No pass pre-filtering - scans every 20s checking for close approaches
    while t <= end {
        for body in ["Sun", "Moon"] {
            match compute_topo_vectors(&elements, t, &observer_ecef, observer_lat_rad, observer_lon_rad, body) {
                Ok((sat_topo, body_topo, sat_alt, body_alt)) => {
                    if sat_alt < alt_min || body_alt < 0.0 {
                        continue;
                    }
                    
                    let sep = angle_between(&sat_topo, &body_topo).to_degrees();
                    let body_distance = body_topo.norm();
                    let body_radius_km = match body {
                        "Sun" => SUN_RADIUS_KM,
                        "Moon" => MOON_RADIUS_KM,
                        _ => continue,
                    };
                    let body_radius_deg = (body_radius_km / body_distance).asin().to_degrees();
                    
                    if sep <= body_radius_deg + near_margin_deg + 2.0 {
                        match refine_minimum(&elements, t, &observer_ecef, observer_lat_rad, observer_lon_rad, body, refine_window_s, fine_step_s) {
                            Ok((t_min, min_sep_deg, radius_deg, sat_alt_refined, sat_az_refined, body_alt_refined, sat_range)) => {
                                let mut kind = if min_sep_deg <= radius_deg {
                                    "transit"
                                } else if min_sep_deg <= radius_deg + near_margin_deg {
                                    "near"
                                } else {
                                    ""
                                };
                                
                                // Check if event is "reachable" (within travel distance)
                                if kind.is_empty() && sat_range > 0.0 && max_distance_km > 0.0 {
                                    // Calculate ground distance needed to travel to see the transit
                                    // Using small angle approximation: arc_length ≈ angle_rad × distance
                                    let required_travel_km = min_sep_deg.to_radians() * sat_range;
                                    if required_travel_km <= max_distance_km && body_alt_refined >= 0.0 {
                                        kind = "reachable";
                                    }
                                }
                                
                                if kind.is_empty() {
                                    continue;
                                }
                                
                                let (speed_deg_per_s, velocity_alt_deg_per_s, velocity_az_deg_per_s, motion_direction_deg) = calculate_speed_and_duration(
                                    &elements, t_min, &observer_ecef, observer_lat_rad, observer_lon_rad, body, fine_step_s
                                ).unwrap_or((0.0, 0.0, 0.0, 0.0));
                                
                                let duration_s = calculate_transit_duration(min_sep_deg, radius_deg, speed_deg_per_s);
                                
                                let sat_ang_size = if sat_range > 0.0 {
                                    let size_km = ISS_DIMENSION_M / 1000.0;
                                    (size_km / sat_range).to_degrees() * 3600.0
                                } else {
                                    0.0
                                };
                                
                                events.push(Event {
                                    time_utc: t_min.to_rfc3339(),
                                    body: body.to_string(),
                                    separation_arcmin: min_sep_deg * 60.0,
                                    target_radius_arcmin: radius_deg * 60.0,
                                    kind: kind.to_string(),
                                    sat_alt_deg: sat_alt_refined,
                                    sat_az_deg: sat_az_refined,
                                    target_alt_deg: body_alt_refined,
                                    satellite: "ISS (ZARYA)".to_string(),
                                    speed_deg_per_s,
                                    speed_arcmin_per_s: speed_deg_per_s * 60.0,
                                    velocity_alt_deg_per_s,
                                    velocity_az_deg_per_s,
                                    motion_direction_deg,
                                    duration_s,
                                    sat_angular_size_arcsec: sat_ang_size,
                                    sat_distance_km: sat_range,
                                });
                                
                                info!("Event found: {} {} at {}", kind, body, t_min);
                                t = t_min + Duration::seconds(300);
                                break;
                            }
                            Err(e) => {
                                warn!("Refinement error: {}", e);
                            }
                        }
                    }
                }
                Err(e) => {
                    warn!("Computation error at {}: {}", t, e);
                }
            }
        }
        
        t = t + Duration::seconds(coarse_step_s as i64);
    }
    
    events.sort_by_key(|e| e.time_utc.clone());
    
    info!("Found {} event(s)", events.len());
    
    let json = serde_json::to_string(&events).unwrap_or_else(|_| "[]".to_string());
    CString::new(json).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn free_json(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        let _ = CString::from_raw(ptr);
    }
}

// ============================================================================
// Unit Tests (for private functions)
// ============================================================================
// Integration tests are in tests/integration_tests.rs

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn test_vector3_operations() {
        let v1 = Vector3::new(3.0, 4.0, 0.0);
        let v2 = Vector3::new(1.0, 0.0, 0.0);
        
        assert_eq!(v1.norm(), 5.0);
        assert_eq!(v1.dot(&v2), 3.0);
        
        let v3 = v1.sub(&v2);
        assert_eq!(v3.x, 2.0);
        assert_eq!(v3.y, 4.0);
        assert_eq!(v3.z, 0.0);
    }

    #[test]
    fn test_observer_ecef_position() {
        // Test Paris coordinates
        let lat: f64 = 48.8566;
        let lon: f64 = 2.3522;
        let alt_m = 35.0;
        
        let lat_rad = lat.to_radians();
        let lon_rad = lon.to_radians();
        let ecef = geodetic_to_ecef(lat_rad, lon_rad, alt_m);
        
        // Verify position is reasonable (somewhere near Earth's surface)
        let radius = ecef.norm();
        assert!(radius > 6300.0 && radius < 6500.0, "ECEF radius should be near Earth radius");
        
        // Verify it's in the northern hemisphere (positive Z for northern lat)
        assert!(ecef.z > 0.0, "Z component should be positive for northern latitude");
    }

    #[test]
    fn test_datetime_to_jd() {
        // Test J2000.0 epoch (January 1, 2000, 12:00 TT)
        let j2000 = Utc.with_ymd_and_hms(2000, 1, 1, 12, 0, 0).unwrap();
        let jd = datetime_to_jd(j2000);
        
        // J2000.0 = JD 2451545.0
        assert!((jd - 2451545.0).abs() < 0.1, "J2000 JD should be ~2451545.0");
    }

    #[test]
    fn test_gmst() {
        // Test GMST calculation for a known time
        let dt = Utc.with_ymd_and_hms(2025, 10, 5, 0, 0, 0).unwrap();
        let jd = datetime_to_jd(dt);
        let gmst_radians = gmst_rad(jd);
        
        // GMST should be between 0 and 2π
        assert!(gmst_radians >= 0.0 && gmst_radians < 2.0 * PI);
    }

    #[test]
    fn test_teme_to_ecef() {
        // Test coordinate transformation with a simple vector
        let teme = Vector3::new(7000.0, 0.0, 0.0);
        let dt = Utc.with_ymd_and_hms(2025, 10, 5, 0, 0, 0).unwrap();
        
        let jd = datetime_to_jd(dt);
        let gmst_radians = gmst_rad(jd);
        let rot = rot_z(gmst_radians);
        let ecef = mat_mul_vec(&rot, &teme);
        
        // Magnitude should be preserved
        assert!((ecef.norm() - teme.norm()).abs() < 0.1);
    }

    #[test]
    fn test_sun_position() {
        // Test Sun position for a known date
        let dt = Utc.with_ymd_and_hms(2025, 10, 5, 12, 0, 0).unwrap();
        let jd = datetime_to_jd(dt);
        let sun_eci = sun_position_eci(jd);
        
        // Sun distance should be approximately 1 AU
        let distance = sun_eci.norm();
        assert!(distance > 145_000_000.0 && distance < 153_000_000.0, 
                "Sun distance should be ~1 AU (149.6 million km)");
    }

    #[test]
    fn test_moon_position() {
        // Test Moon position for a known date
        let dt = Utc.with_ymd_and_hms(2025, 10, 5, 12, 0, 0).unwrap();
        let jd = datetime_to_jd(dt);
        let moon_eci = moon_position_eci(jd);
        
        // Moon distance should be between 356,000 and 406,000 km (perigee to apogee)
        let distance = moon_eci.norm();
        assert!(distance > 350_000.0 && distance < 410_000.0,
                "Moon distance should be ~384,400 km ± range");
    }

    #[test]
    fn test_altaz_conversion() {
        // Test altitude/azimuth calculation
        // Vector pointing straight up (zenith)
        let zenith = Vector3::new(0.0, 0.0, 100.0);
        let (alt, _az) = altaz(&zenith);
        
        assert!((alt - 90.0).abs() < 0.01, "Zenith altitude should be 90°");
        
        // Vector pointing north
        let north = Vector3::new(-100.0, 0.0, 0.0);
        let (alt_n, az_n) = altaz(&north);
        
        assert!((alt_n - 0.0).abs() < 0.01, "Horizon altitude should be 0°");
        assert!((az_n - 0.0).abs() < 0.01, "North azimuth should be 0°");
    }

    #[test]
    fn test_ecef_to_sez() {
        // Test ECEF to SEZ (topocentric) transformation
        let ecef_vec = Vector3::new(1000.0, 0.0, 0.0);
        let lat_rad = 0.0; // Equator
        let lon_rad = 0.0; // Prime meridian
        
        let sez = ecef_to_sez(&ecef_vec, lat_rad, lon_rad);
        
        // At equator and prime meridian, X ECEF should map to -X SEZ (south)
        assert!((sez.x - 0.0).abs() < 1.0);
    }

    #[test]
    fn test_sgp4_propagation() {
        // Test SGP4 propagation with a real ISS TLE
        let tle1 = "1 25544U 98067A   25278.49802050  .00011384  00000+0  20935-3 0  9990";
        let tle2 = "2 25544  51.6327 120.3420 0000884 206.2421 153.8523 15.49697304532279";
        
        let elements = sgp4::Elements::from_tle(
            Some("ISS (ZARYA)".to_string()),
            tle1.as_bytes(),
            tle2.as_bytes(),
        ).expect("Failed to parse TLE");
        
        // Test position at TLE epoch
        let epoch_dt = DateTime::<Utc>::from_naive_utc_and_offset(elements.datetime, Utc);
        
        let pos = get_sat_position(&elements, epoch_dt);
        assert!(pos.is_ok(), "SGP4 propagation should succeed");
        
        let teme_pos = pos.unwrap();
        let altitude = teme_pos.norm() - EARTH_RADIUS_KM;
        
        // ISS altitude should be between 400-450 km typically
        assert!(altitude > 350.0 && altitude < 500.0,
                "ISS altitude should be ~400-450 km, got {}", altitude);
    }

    #[test]
    fn test_angular_radius() {
        // Helper function for tests
        fn angular_radius_deg(radius_km: f64, distance_km: f64) -> f64 {
            (radius_km / distance_km).asin().to_degrees()
        }
        
        // Test angular radius calculation
        // Sun at 1 AU should have angular radius ~0.267° (16 arcmin)
        let sun_angular_rad_deg = angular_radius_deg(SUN_RADIUS_KM, AU_KM);
        assert!((sun_angular_rad_deg - 0.267).abs() < 0.01,
                "Sun angular radius should be ~0.267°");
        
        // Moon at mean distance should have angular radius ~0.259° (15.5 arcmin)
        let moon_angular_rad_deg = angular_radius_deg(MOON_RADIUS_KM, 384_400.0);
        assert!((moon_angular_rad_deg - 0.259).abs() < 0.01,
                "Moon angular radius should be ~0.259°");
    }

    #[test]
    fn test_calculate_transit_duration() {
        // Test transit duration calculation
        // Satellite crossing dead center of Sun at 0.3°/s
        let sep_deg = 0.0;
        let radius_deg = 0.267; // Sun radius
        let speed = 0.3; // deg/s
        
        let duration = calculate_transit_duration(sep_deg, radius_deg, speed);
        
        // Duration = 2*radius/speed = 2*0.267/0.3 ≈ 1.78 seconds
        assert!((duration - 1.78).abs() < 0.1,
                "Central transit duration should be ~1.78s");
        
        // Test non-central transit
        let sep_deg_offset = 0.15; // Offset from center
        let duration_offset = calculate_transit_duration(sep_deg_offset, radius_deg, speed);
        assert!(duration_offset < duration, "Off-center transit should be shorter");
    }

    #[test]
    fn test_separation_calculation() {
        // Test angular separation between two vectors
        // Two identical vectors should have 0 separation
        let v1 = Vector3::new(1.0, 0.0, 0.0);
        let v2 = Vector3::new(1.0, 0.0, 0.0);
        
        let sep_rad = angle_between(&v1, &v2);
        assert!(sep_rad.abs() < 0.001, "Identical vectors should have 0 separation");
        
        // Perpendicular vectors should have 90° separation
        let v3 = Vector3::new(0.0, 1.0, 0.0);
        let sep_rad_perp = angle_between(&v1, &v3);
        assert!((sep_rad_perp - PI/2.0).abs() < 0.001,
                "Perpendicular vectors should have π/2 separation");
    }
}
