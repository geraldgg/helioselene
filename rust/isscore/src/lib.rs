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
struct Event {
    time_utc: String,
    body: String,
    separation_arcmin: f64,
    target_radius_arcmin: f64,
    kind: String,
    iss_alt_deg: f64,
    target_alt_deg: f64,
    satellite: String,
    speed_deg_per_s: f64,
    speed_arcmin_per_s: f64,
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
    let az_rad = topo_vec.y.atan2(topo_vec.x);
    (alt_rad.to_degrees(), az_rad.to_degrees())
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
) -> Result<(DateTime<Utc>, f64, f64, f64, f64, f64), String> {
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
    
    let (_, body_topo, _, _) = compute_topo_vectors(elements, best_time, observer_ecef, observer_lat_rad, observer_lon_rad, body)?;
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
) -> Result<f64, String> {
    let t_minus = t_min - Duration::milliseconds((step_s * 1000.0) as i64);
    let t_plus = t_min + Duration::milliseconds((step_s * 1000.0) as i64);
    
    let (sat_m, _, _, _) = compute_topo_vectors(elements, t_minus, observer_ecef, observer_lat_rad, observer_lon_rad, body)?;
    let (sat_p, _, _, _) = compute_topo_vectors(elements, t_plus, observer_ecef, observer_lat_rad, observer_lon_rad, body)?;
    
    let (alt_m, az_m) = altaz(&sat_m);
    let (alt_p, az_p) = altaz(&sat_p);
    
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
    
    Ok(speed_rad_per_s.to_degrees())
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
                            Ok((t_min, min_sep_deg, radius_deg, sat_alt_refined, body_alt_refined, sat_range)) => {
                                let kind = if min_sep_deg <= radius_deg {
                                    "transit"
                                } else if min_sep_deg <= radius_deg + near_margin_deg {
                                    "near"
                                } else {
                                    continue;
                                };
                                
                                let speed_deg_per_s = calculate_speed_and_duration(
                                    &elements, t_min, &observer_ecef, observer_lat_rad, observer_lon_rad, body, fine_step_s
                                ).unwrap_or(0.0);
                                
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
                                    iss_alt_deg: sat_alt_refined,
                                    target_alt_deg: body_alt_refined,
                                    satellite: "ISS (ZARYA)".to_string(),
                                    speed_deg_per_s,
                                    speed_arcmin_per_s: speed_deg_per_s * 60.0,
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
