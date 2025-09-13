use std::ffi::{CStr, CString, c_char};
use serde::Serialize;
use chrono::{DateTime, Utc, Duration};
use chrono::Datelike;
use chrono::Timelike;

// SGP4 v2.3
use sgp4::{Elements, Constants, MinutesSinceEpoch};
// Sun/Moon positions & distances
use practical_astronomy_rust::{sun as pa_sun, moon as pa_moon};
use log::{info, debug, warn, error};
use std::sync::Once;

// ---------- Constants ----------
const SUN_RADIUS_KM: f64 = 696_340.0;
const MOON_RADIUS_KM: f64 = 1_737.4;
const ISS_CHAR_LEN_M: f64 = 109.0;

const EARTH_RADIUS_KM: f64 = 6378.137;                 // WGS-84 equatorial
const EARTH_FLATTENING: f64 = 1.0 / 298.257_223_563;   // WGS-84

const SUN_MIN_ALT_DEG: f64 = -5.0;
const MOON_MIN_ALT_DEG: f64 = 5.0;
const DEFAULT_ALT_MIN_DEG: f64 = 5.0;
const COARSE_STEP_S: i64 = 20;
const FINE_STEP_S: f64 = 1.0;
const REFINEMENT_WINDOW_S: i64 = 60;
const MAX_REACH_DISTANCE_KM: f64 = 35.0; // approximate max drive distance for 'Reachable' classification
const ROUGH_REFINE_BUFFER_DEG: f64 = 2.0; // extra degrees added to radius+margin for refinement prefilter (matches Python logic)

// ---------- Output model ----------
#[derive(Serialize, Debug)]
struct Transit {
    t_center_epoch: i64,       // UTC seconds since epoch
    body: String,              // "Sun" or "Moon"
    kind: String,              // "Transit" or "Near"
    min_sep_arcsec: f64,
    duration_s: f64,
    body_alt_deg: f64,
    sat_range_km: f64,         // Generic satellite range (was iss_range_km)
    sat_ang_size_arcsec: f64,  // Generic satellite angular size (was iss_ang_size_arcsec)
    satellite: String,         // Satellite name (ISS, Tiangong, Hubble)
}

// ---------- C ABI ----------
#[no_mangle]
pub extern "C" fn free_json(ptr: *mut c_char) {
    if ptr.is_null() { return; }
    unsafe { let _ = CString::from_raw(ptr); }
}

static INIT_LOGGER: Once = Once::new();

#[cfg(target_os = "android")]
fn init_logger() {
    use android_logger::Config;
    use log::LevelFilter;
    INIT_LOGGER.call_once(|| {
        android_logger::init_once(
            Config::default()
                .with_max_level(LevelFilter::Debug)
                .with_tag("isscore")
        );
    });
}

#[cfg(not(target_os = "android"))]
fn init_logger() {
    INIT_LOGGER.call_once(|| {
        let _ = env_logger::Builder::from_default_env()
            .filter_level(log::LevelFilter::Debug)
            .try_init();
    });
}

#[no_mangle]
pub extern "C" fn predict_transits_v2(
    tle1: *const c_char,
    tle2: *const c_char,
    lat: f64, lon: f64, alt_m: f64,
    start_epoch: i64, end_epoch: i64,
    near_arcmin: f64,
) -> *mut c_char {
    init_logger();
    info!("[predict_transits_v2] Starting prediction");
    debug!("[predict_transits_v2] called with:");
    debug!("  tle1: {}", unsafe { CStr::from_ptr(tle1) }.to_string_lossy());
    debug!("  tle2: {}", unsafe { CStr::from_ptr(tle2) }.to_string_lossy());
    debug!("  lat: {}, lon: {}, alt_m: {}", lat, lon, alt_m);
    debug!("  start_epoch: {}, end_epoch: {}", start_epoch, end_epoch);
    debug!("  near_arcmin: {}", near_arcmin);

    // Read C strings safely
    let tle1 = unsafe { CStr::from_ptr(tle1) }.to_string_lossy().into_owned();
    let tle2 = unsafe { CStr::from_ptr(tle2) }.to_string_lossy().into_owned();

    // Determine satellite name from TLE
    let sat_name = determine_satellite_name(&tle1, &tle2);
    info!("[predict_transits_v2] Detected satellite: {}", sat_name);

    // Parse TLE / init SGP4
    let elements = match Elements::from_tle(None, tle1.as_bytes(), tle2.as_bytes()) {
        Ok(e) => {
            info!("[predict_transits_v2] TLE parsed successfully");
            e
        },
        Err(e) => {
            error!("[predict_transits_v2] Failed to parse TLE: {}", e);
            return CString::new("[]").unwrap().into_raw();
        },
    };
    let constants = match Constants::from_elements(&elements) {
        Ok(c) => c,
        Err(e) => {
            error!("[predict_transits_v2] Failed to get constants: {}", e);
            return CString::new("[]").unwrap().into_raw();
        },
    };

    // Time window
    let start = DateTime::<Utc>::from_timestamp(start_epoch, 0).unwrap_or_else(|| DateTime::<Utc>::from_timestamp(0, 0).unwrap());
    let end = DateTime::<Utc>::from_timestamp(end_epoch, 0).unwrap_or_else(|| DateTime::<Utc>::from_timestamp(0, 0).unwrap());
    info!("[predict_transits_v2] Time window: {} to {}", start, end);

    let total_days = (end - start).num_days();
    let total_seconds = (end - start).num_seconds();
    info!("[predict_transits_v2] Search duration: {} days ({} seconds)", total_days, total_seconds);

    // Precompute observer geocentric ECEF
    let (ox, oy, oz) = observer_ecef(lat, lon, alt_m);
    debug!("[predict_transits_v2] Observer ECEF: x={:.3}, y={:.3}, z={:.3} km", ox, oy, oz);

    // Convert near_arcmin to degrees for easier comparison
    let near_margin_deg = near_arcmin / 60.0;
    debug!("[predict_transits_v2] Near margin: {:.3}° ({:.1} arcmin)", near_margin_deg, near_arcmin);

    let mut events: Vec<Transit> = Vec::new();

    // Step 1: Coarse scan to find satellite passes above minimum altitude
    debug!("[predict_transits_v2] Starting coarse scan for {} passes", sat_name);
    info!("[predict_transits_v2] Building time grid with {:.0}s steps", COARSE_STEP_S);

    // --- BEGIN: Log first 10 satellite altitudes for debugging ---
    let mut t_dbg = start;
    for i in 0..10 {
        let alt_dbg = satellite_altitude(&elements, &constants, t_dbg, lat, lon, ox, oy, oz);
        debug!("[predict_transits_v2] Altitude sample {}: t={} alt={:.1}°", i+1, t_dbg, alt_dbg);
        t_dbg = t_dbg + Duration::seconds(COARSE_STEP_S);
    }
    // --- END: Log first 10 satellite altitudes for debugging ---

    let pass_intervals = find_satellite_pass_intervals(&elements, &constants, start, end, lat, lon, ox, oy, oz, DEFAULT_ALT_MIN_DEG);
    info!("[predict_transits_v2] Found {} {} pass intervals above {}°", pass_intervals.len(), sat_name, DEFAULT_ALT_MIN_DEG);

    if pass_intervals.is_empty() {
        warn!("[predict_transits_v2] No satellite passes found above minimum altitude {}°", DEFAULT_ALT_MIN_DEG);
        warn!("[predict_transits_v2] This might indicate:");
        warn!("  - Satellite not visible from this location during time window");
        warn!("  - TLE data might be outdated");
        warn!("  - Observer location or time window issues");
        return CString::new("[]").unwrap().into_raw();
    }

    // Step 2: For each pass, scan for Sun/Moon events
    for (pass_idx, (pass_start, pass_end)) in pass_intervals.iter().enumerate() {
        debug!("[predict_transits_v2] Processing {} pass {}/{} from {} to {} (duration: {}s)",
            sat_name, pass_idx + 1, pass_intervals.len(), pass_start, pass_end,
            (pass_end.timestamp() - pass_start.timestamp()));

        let mut t = *pass_start;
        let mut step_count = 0;
        while t <= *pass_end {
            step_count += 1;

            // Check satellite altitude - skip if too low
            let sat_alt = satellite_altitude(&elements, &constants, t, lat, lon, ox, oy, oz);
            if sat_alt < DEFAULT_ALT_MIN_DEG {
                t = t + Duration::seconds(COARSE_STEP_S);
                continue;
            }

            if step_count % 10 == 0 {
                debug!("[predict_transits_v2] Pass scan step {}: t={}, sat_alt={:.1}°", step_count, t, sat_alt);
            }

            // Check both Sun and Moon
            for body_name in ["Sun", "Moon"] {
                let (sep_deg, radius_deg, body_alt_deg, _sat_range_km) =
                    sep_radius_alt_satellite(&elements, &constants, t, lat, lon, ox, oy, oz, body_name);

                // Skip if body is too low
                let min_alt = if body_name == "Sun" { SUN_MIN_ALT_DEG } else { MOON_MIN_ALT_DEG };
                if body_alt_deg < min_alt {
                    if step_count % 20 == 0 {
                        debug!("[predict_transits_v2] {} altitude too low: {:.1}° < {:.1}°", body_name, body_alt_deg, min_alt);
                    }
                    continue;
                }

                // Log interesting cases
                let max_interesting_sep_strict = radius_deg + near_margin_deg; // final classification boundary
                let refine_threshold = radius_deg + near_margin_deg + ROUGH_REFINE_BUFFER_DEG; // looser prefilter
                if sep_deg <= max_interesting_sep_strict {
                    info!("[predict_transits_v2] INTERESTING (strict): t={}, satellite={}, body={}, sep={:.3}°, radius={:.3}°, body_alt={:.1}°, sat_alt={:.1}°", t, sat_name, body_name, sep_deg, radius_deg, body_alt_deg, sat_alt);
                } else if sep_deg <= refine_threshold {
                    debug!("[predict_transits_v2] WITHIN REFINEMENT BUFFER: t={}, sep={:.3}° (limit {:.3}°) radius={:.3}°", t, sep_deg, refine_threshold, radius_deg);
                } else if step_count % 30 == 0 {
                    debug!("[predict_transits_v2] t={}, satellite={}, body={}, sep={:.3}° (> {:.3}° buffer limit)", t, sat_name, body_name, sep_deg, refine_threshold);
                }

                // Skip if separation is too large even for buffered refinement
                if sep_deg > refine_threshold {
                    continue;
                }

                // Found potential event - refine timing
                info!("[predict_transits_v2] REFINING: Potential {} {} event at {}, sep={:.3}°, radius={:.3}°", sat_name, body_name, t, sep_deg, radius_deg);
                let (refined_time, min_sep_deg, refined_radius_deg, refined_body_alt, refined_sat_alt, refined_sat_range) =
                    refine_event_timing(&elements, &constants, t, lat, lon, ox, oy, oz, body_name);

                info!("[predict_transits_v2] REFINED: t={}, min_sep={:.3}°, radius={:.3}°", refined_time, min_sep_deg, refined_radius_deg);

                // Classify event
                let mut kind = if min_sep_deg <= refined_radius_deg {
                    "Transit".to_string()
                } else if min_sep_deg <= (refined_radius_deg + near_margin_deg) {
                    "Near".to_string()
                } else {
                    String::new()
                };

                if kind.is_empty() {
                    // Parallax reachability approximation: linear offset ≈ θ * range
                    if refined_sat_range > 0.0 {
                        let sep_rad = min_sep_deg.to_radians();
                        let required_km = sep_rad * refined_sat_range;
                        if required_km <= MAX_REACH_DISTANCE_KM && refined_body_alt >= 0.0 && refined_sat_alt >= DEFAULT_ALT_MIN_DEG {
                            kind = "Reachable".to_string();
                            debug!("[predict_transits_v2] REACHABLE classification: sep={:.3}° radius={:.3}° required_offset={:.2} km", min_sep_deg, refined_radius_deg, required_km);
                        } else {
                            debug!("[predict_transits_v2] Rejected: sep={:.3}° (limit {:.3}°) required_offset={:.2} km", min_sep_deg, refined_radius_deg + near_margin_deg, required_km);
                        }
                    }
                }

                if kind.is_empty() {
                    info!("[predict_transits_v2] Event rejected after refinement: sep={:.3}° > limit={:.3}°",
                        min_sep_deg, refined_radius_deg + near_margin_deg);
                    continue; // Skip if not interesting after refinement
                }

                info!("[predict_transits_v2] EVENT CLASSIFIED: {} (sep={:.3}°, radius={:.3}°, margin={:.3}°)",
                    kind, min_sep_deg, refined_radius_deg, near_margin_deg);

                // Calculate duration and satellite angular size
                let rate_deg_s = estimate_separation_rate(&elements, &constants, refined_time, lat, lon, ox, oy, oz, body_name);
                let duration_s = if min_sep_deg <= refined_radius_deg && rate_deg_s > 0.0 {
                    chord_duration(refined_radius_deg, min_sep_deg, rate_deg_s)
                } else {
                    0.0
                };

                let sat_ang_size_arcsec = if refined_sat_range > 0.0 {
                    (ISS_CHAR_LEN_M / 1000.0 / refined_sat_range).to_degrees() * 3600.0
                } else {
                    0.0
                };

                let transit = Transit {
                    t_center_epoch: refined_time.timestamp(),
                    body: body_name.to_string(),
                    kind: kind.to_string(),
                    min_sep_arcsec: min_sep_deg * 3600.0,
                    duration_s,
                    body_alt_deg: refined_body_alt,
                    sat_range_km: refined_sat_range,
                    sat_ang_size_arcsec: sat_ang_size_arcsec,
                    satellite: sat_name.clone(),
                };

                info!("[predict_transits_v2] EVENT CREATED: {} {} {} at {}: sep={:.1}\" duration={:.1}s",
                    kind, sat_name, body_name, refined_time, transit.min_sep_arcsec, duration_s);
                events.push(transit);

                // Skip ahead to avoid duplicate detections
                t = refined_time + Duration::seconds(300); // 5 minutes
                break; // Break inner loop to advance time
            }

            if t == *pass_start + Duration::seconds((t.timestamp() - pass_start.timestamp()) / COARSE_STEP_S * COARSE_STEP_S) {
                t = t + Duration::seconds(COARSE_STEP_S);
            }
        }

        debug!("[predict_transits_v2] Completed pass {}/{}, processed {} time steps",
            pass_idx + 1, pass_intervals.len(), step_count);
    }

    info!("[predict_transits_v2] FINAL RESULT: Found {} total events for {}", events.len(), sat_name);

    // Sort events by time
    events.sort_by_key(|e| e.t_center_epoch);

    let json = serde_json::to_string(&events).unwrap_or_else(|_| "[]".to_string());
    info!("[predict_transits_v2] Returning JSON with {} events", events.len());
    CString::new(json).unwrap().into_raw()
}

// New function to determine satellite name from TLE
fn determine_satellite_name(tle1: &str, _tle2: &str) -> String {
    // Extract NORAD catalog number from line 1
    if tle1.len() >= 7 {
        let catalog_num = tle1[2..7].trim();
        match catalog_num {
            "25544" => "ISS".to_string(),
            "48274" => "Tiangong".to_string(),
            "20580" => "Hubble".to_string(),
            _ => format!("SAT-{}", catalog_num),
        }
    } else {
        "Unknown".to_string()
    }
}

// Find intervals where satellite is above minimum altitude
fn find_satellite_pass_intervals(
    elements: &Elements,
    constants: &Constants,
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    lat: f64, lon: f64,
    ox: f64, oy: f64, oz: f64,
    alt_min: f64
) -> Vec<(DateTime<Utc>, DateTime<Utc>)> {
    let mut intervals = Vec::new();
    let mut t = start;
    let mut in_pass = false;
    let mut pass_start = start;

    while t <= end {
        let alt = satellite_altitude(elements, constants, t, lat, lon, ox, oy, oz);

        if !in_pass && alt >= alt_min {
            // Start of pass
            in_pass = true;
            pass_start = t;
        } else if in_pass && alt < alt_min {
            // End of pass
            in_pass = false;
            intervals.push((pass_start, t - Duration::seconds(COARSE_STEP_S)));
        }

        t = t + Duration::seconds(COARSE_STEP_S);
    }

    // Handle case where pass extends to end of time window
    if in_pass {
        intervals.push((pass_start, end));
    }

    intervals
}

// Calculate satellite altitude at a given time
fn satellite_altitude(
    elements: &Elements,
    constants: &Constants,
    t: DateTime<Utc>,
    lat: f64, lon: f64,
    ox: f64, oy: f64, oz: f64
) -> f64 {
    // Propagate satellite position to ECEF
    let minutes: MinutesSinceEpoch = elements
        .datetime_to_minutes_since_epoch(&t.naive_utc())
        .unwrap();
    let pred = constants.propagate(minutes).unwrap();
    let r_teme = pred.position; // [x, y, z] km (TEME/ECI-like)

    // GMST for rotation
    let gmst = gmst_deg(
        t.year(), t.month(), t.day(),
        t.hour(), t.minute(),
        t.second() as f64 + (t.timestamp_subsec_micros() as f64)/1.0e6
    );

    // Print TEME/ECI and GMST for first sample (for cross-check)
    if t.year() == 2025 && t.month() == 9 && t.day() == 13 && t.hour() == 20 && t.minute() == 0 && t.second() == 0 {
        debug!("[predict_transits_v2] Sat TEME/ECI at {}: x={:.3}, y={:.3}, z={:.3} km", t, r_teme[0], r_teme[1], r_teme[2]);
        debug!("[predict_transits_v2] GMST at {}: {:.6} deg", t, gmst);
    }

    let theta = gmst.to_radians();
    let (ct, st) = (theta.cos(), theta.sin());

    // TEME (≈ECI) → ECEF
    let x_ecef_sat =  ct * r_teme[0] + st * r_teme[1];
    let y_ecef_sat = -st * r_teme[0] + ct * r_teme[1];
    let z_ecef_sat =  r_teme[2];

    // Print ECEF for first sample (for cross-check)
    if t.year() == 2025 && t.month() == 9 && t.day() == 13 && t.hour() == 20 && t.minute() == 0 && t.second() == 0 {
        debug!("[predict_transits_v2] Sat ECEF at {}: x={:.3}, y={:.3}, z={:.3} km", t, x_ecef_sat, y_ecef_sat, z_ecef_sat);
    }

    // Observer ECEF is (ox, oy, oz)
    // Topocentric vector from observer to satellite
    let dx = x_ecef_sat - ox;
    let dy = y_ecef_sat - oy;
    let dz = z_ecef_sat - oz;

    // Observer geodetic lat/lon in radians
    let lat_rad = lat.to_radians();
    let lon_rad = lon.to_radians();

    // ENU basis vectors
    let sin_lat = lat_rad.sin();
    let cos_lat = lat_rad.cos();
    let sin_lon = lon_rad.sin();
    let cos_lon = lon_rad.cos();

    // Up vector (local zenith)
    let up_x = cos_lat * cos_lon;
    let up_y = cos_lat * sin_lon;
    let up_z = sin_lat;

    // Dot product of topocentric vector with Up vector
    let up = dx * up_x + dy * up_y + dz * up_z;
    let norm = (dx*dx + dy*dy + dz*dz).sqrt();
    let alt_rad = (up / norm).asin();
    alt_rad.to_degrees()
}

// Refine event timing around a coarse detection
fn refine_event_timing(
    elements: &Elements,
    constants: &Constants,
    t_center: DateTime<Utc>,
    lat: f64, lon: f64,
    ox: f64, oy: f64, oz: f64,
    body: &str
) -> (DateTime<Utc>, f64, f64, f64, f64, f64) {
    let mut best_time = t_center;
    let mut min_sep = f64::INFINITY;
    let mut best_radius = 0.0;
    let mut best_body_alt = 0.0;
    let mut best_sat_alt = 0.0;
    let mut best_sat_range = 0.0;

    let window_start = t_center - Duration::seconds(REFINEMENT_WINDOW_S);
    let window_end = t_center + Duration::seconds(REFINEMENT_WINDOW_S);

    let steps = (2 * REFINEMENT_WINDOW_S) as f64 / FINE_STEP_S;
    for i in 0..=(steps as i32) {
        let t = window_start + Duration::milliseconds((i as f64 * FINE_STEP_S * 1000.0) as i64);
        if t < window_start || t > window_end {
            continue;
        }

        let (sep_deg, radius_deg, body_alt_deg, sat_range_km) =
            sep_radius_alt_satellite(elements, constants, t, lat, lon, ox, oy, oz, body);

        if sep_deg < min_sep {
            min_sep = sep_deg;
            best_time = t;
            best_radius = radius_deg;
            best_body_alt = body_alt_deg;
            best_sat_alt = satellite_altitude(elements, constants, t, lat, lon, ox, oy, oz);
            best_sat_range = sat_range_km;
        }
    }

    (best_time, min_sep, best_radius, best_body_alt, best_sat_alt, best_sat_range)
}

// Estimate the rate of change of separation (for duration calculation)
fn estimate_separation_rate(
    elements: &Elements,
    constants: &Constants,
    t: DateTime<Utc>,
    lat: f64, lon: f64,
    ox: f64, oy: f64, oz: f64,
    body: &str
) -> f64 {
    let dt = Duration::milliseconds((FINE_STEP_S * 1000.0) as i64);
    let (sep_before, _, _, _) = sep_radius_alt_satellite(elements, constants, t - dt, lat, lon, ox, oy, oz, body);
    let (sep_after, _, _, _) = sep_radius_alt_satellite(elements, constants, t + dt, lat, lon, ox, oy, oz, body);
    (sep_after - sep_before).abs() / (2.0 * FINE_STEP_S)
}

// ---------- Core geometry ----------

// Calculate angular radius from satellite perspective (like Python's angular_radius_deg)
fn angular_radius_deg(physical_radius_km: f64, distance_km: f64) -> f64 {
    if distance_km <= 0.0 {
        return 0.0;
    }
    let ratio = (physical_radius_km / distance_km).min(1.0);
    ratio.asin().to_degrees()
}

// Renamed function to be more generic - now uses physical radii for accurate calculations
fn sep_radius_alt_satellite(
    elements: &Elements,
    constants: &Constants,
    t: DateTime<Utc>,
    lat: f64, lon: f64,
    ox: f64, oy: f64, oz: f64,
    body: &str
) -> (f64, f64, f64, f64) {
    // Get Sun/Moon RA/Dec and altitude from observer perspective
    let (ra_body, dec_body, body_alt_deg) = {
        let y = t.year() as u32;
        let mo = t.month();
        let d = t.day();
        let hh = t.hour() as f64;
        let mm = t.minute() as f64;
        let ss = t.second() as f64 + (t.timestamp_subsec_micros() as f64)/1.0e6;

        if body == "Sun" {
            let (ra_h, ra_m, ra_s, dec_d, dec_m, dec_s) =
                pa_sun::precise_position_of_sun(hh, mm, ss, d as f64, mo, y, false, 0);
            let ra = hms_to_deg(ra_h, ra_m, ra_s);
            let dec = dms_to_deg(dec_d, dec_m, dec_s);
            let alt = alt_from_ra_dec(ra, dec, lat, lon, t);
            (ra, dec, alt)
        } else {
            let (ra_h, ra_m, ra_s, dec_d, dec_m, dec_s, _el, _par) =
                pa_moon::precise_position_of_moon(hh, mm, ss, false, 0, d as f64, mo, y);
            let ra = hms_to_deg(ra_h, ra_m, ra_s);
            let dec = dms_to_deg(dec_d, dec_m, dec_s);
            let alt = alt_from_ra_dec(ra, dec, lat, lon, t);
            (ra, dec, alt)
        }
    };

    // Calculate distance from satellite to Sun/Moon for accurate angular radius
    let (body_distance_km, physical_radius_km) = if body == "Sun" {
        // Use Earth-Sun distance as approximation (satellite is much closer to Earth)
        let (_dist_km, _ang_deg, _ang_min, _ang_sec) = pa_sun::sun_distance_and_angular_size(
            t.hour() as f64, t.minute() as f64,
            t.second() as f64 + (t.timestamp_subsec_micros() as f64)/1.0e6,
            t.day() as f64, t.month(), t.year() as u32, false, 0
        );
        // The practical astronomy library gives us distance in the first return value
        // For now, use standard astronomical unit as approximation
        (149_597_870.7, SUN_RADIUS_KM) // AU in km
    } else {
        // For Moon, get distance from practical astronomy library
        let (_dist_km, _ang_deg, _ang_min, _ang_sec, _hp_deg, _hp_min) =
            pa_moon::moon_dist_ang_diam_hor_parallax(
                t.hour() as f64, t.minute() as f64,
                t.second() as f64 + (t.timestamp_subsec_micros() as f64)/1.0e6,
                false, 0, t.day() as f64, t.month(), t.year() as u32
            );
        // Use standard lunar distance as approximation
        (384_400.0, MOON_RADIUS_KM) // km
    };

    // Calculate accurate angular radius from satellite perspective using physical radius
    let radius_deg = angular_radius_deg(physical_radius_km, body_distance_km);

    // Satellite topocentric RA/Dec + range
    let (sat_ra, sat_dec, sat_range_km) = satellite_topocentric(elements, constants, t, lat, lon, ox, oy, oz);

    // Angular separation between satellite and Sun/Moon
    let sep = angular_separation_deg(sat_ra, sat_dec, ra_body, dec_body);

    debug!("Body: {} at t={}, distance={:.0} km, physical_radius={:.0} km, angular_radius={:.6}°",
           body, t, body_distance_km, physical_radius_km, radius_deg);

    (sep, radius_deg, body_alt_deg, sat_range_km)
}

// Renamed function to be more generic
fn satellite_topocentric(
    elements: &Elements,
    constants: &Constants,
    t: DateTime<Utc>,
    _lat: f64, _lon: f64,  // not strictly needed here
    ox: f64, oy: f64, oz: f64,
) -> (f64, f64, f64) {
    // Propagate to TEME (km)
    let minutes: MinutesSinceEpoch = elements
        .datetime_to_minutes_since_epoch(&t.naive_utc())
        .unwrap();
    let pred = constants.propagate(minutes).unwrap();
    let r_teme = pred.position; // [x, y, z] km (TEME/ECI-like)

    // GMST for rotation
    let gmst = gmst_deg(
        t.year(), t.month(), t.day(),
        t.hour(), t.minute(),
        t.second() as f64 + (t.timestamp_subsec_micros() as f64)/1.0e6
    );
    let theta = gmst.to_radians();
    let (ct, st) = (theta.cos(), theta.sin());

    // TEME (≈ECI) → ECEF
    let x_ecef =  ct * r_teme[0] + st * r_teme[1];
    let y_ecef = -st * r_teme[0] + ct * r_teme[1];
    let z_ecef =  r_teme[2];

    // Topocentric vector from observer
    let rx = x_ecef - ox;
    let ry = y_ecef - oy;
    let rz = z_ecef - oz;
    let range = (rx*rx + ry*ry + rz*rz).sqrt();

    // Back to ECI to get RA/Dec
    let x_eci =  ct * rx - st * ry;
    let y_eci =  st * rx + ct * ry;
    let z_eci =  rz;

    let r = (x_eci*x_eci + y_eci*y_eci + z_eci*z_eci).sqrt();
    let dec = (z_eci / r).asin().to_degrees();
    let mut ra = y_eci.atan2(x_eci).to_degrees();
    ra = unwind_deg(ra);

    (ra, dec, range)
}

// ---------- Utility math ----------

fn observer_ecef(lat_deg: f64, lon_deg: f64, alt_m: f64) -> (f64, f64, f64) {
    // WGS-84
    let a = EARTH_RADIUS_KM;
    let f = EARTH_FLATTENING;
    let e2 = f * (2.0 - f);

    let lat = lat_deg.to_radians();
    let lon = lon_deg.to_radians();

    let sin_lat = lat.sin();
    let cos_lat = lat.cos();

    let n = a / (1.0 - e2 * sin_lat * sin_lat).sqrt();
    let alt_km = alt_m / 1000.0;

    let x = (n + alt_km) * cos_lat * lon.cos();
    let y = (n + alt_km) * cos_lat * lon.sin();
    let z = (n * (1.0 - e2) + alt_km) * sin_lat;

    (x, y, z)
}

fn gmst_deg(year: i32, month: u32, day: u32, hour: u32, minute: u32, second: f64) -> f64 {
    // IAU 2000/2006 GMST, matching Skyfield/Astropy
    // 1. Compute Julian Date (UTC)
    let y = if month > 2 { year as f64 } else { (year as f64) - 1.0 };
    let m = if month > 2 { month as f64 } else { (month as f64) + 12.0 };
    let d = day as f64 + (hour as f64 + (minute as f64 + second / 60.0) / 60.0) / 24.0;
    let a = (y / 100.0).floor();
    let b = 2.0 - a + (a / 4.0).floor();
    let jd = (365.25 * (y + 4716.0)).floor()
        + (30.6001 * (m + 1.0)).floor()
        + d + b - 1524.5;
    // 2. Compute Julian centuries since J2000.0
    let t = (jd - 2451545.0) / 36525.0;
    // 3. GMST in seconds (see Explanatory Supplement to the Astronomical Almanac, 3rd ed., eqn 12.92)
    let gmst_sec = 67310.54841
        + (876600.0 * 3600.0 + 8640184.812866) * t
        + 0.093104 * t * t
        - 6.2e-6 * t * t * t;
    // 4. Convert to degrees
    let mut gmst_deg = (gmst_sec / 240.0) % 360.0;
    if gmst_deg < 0.0 { gmst_deg += 360.0; }
    gmst_deg
}

fn unwind_deg(mut x: f64) -> f64 {
    x %= 360.0;
    if x < 0.0 { x += 360.0; }
    x
}

fn hms_to_deg(h: f64, m: f64, s: f64) -> f64 {
    (h + m/60.0 + s/3600.0) * 15.0
}

fn dms_to_deg(d: f64, m: f64, s: f64) -> f64 {
    let sign = if d < 0.0 { -1.0 } else { 1.0 };
    sign * (d.abs() + m/60.0 + s/3600.0)
}

fn alt_from_ra_dec(ra_deg: f64, dec_deg: f64, lat_deg: f64, lon_deg: f64, t: DateTime<Utc>) -> f64 {
    // LST ≈ GMST + longitude
    let gmst = gmst_deg(
        t.year(), t.month(), t.day(),
        t.hour(), t.minute(),
        t.second() as f64 + (t.timestamp_subsec_micros() as f64)/1.0e6
    );
    let lst = unwind_deg(gmst + lon_deg);

    let h = unwind_deg(lst - ra_deg).to_radians();
    let lat = lat_deg.to_radians();
    let dec = dec_deg.to_radians();

    (lat.sin()*dec.sin() + lat.cos()*dec.cos()*h.cos()).asin().to_degrees()
}

fn angular_separation_deg(ra1_deg: f64, dec1_deg: f64, ra2_deg: f64, dec2_deg: f64) -> f64 {
    let ra1 = ra1_deg.to_radians();
    let ra2 = ra2_deg.to_radians();
    let d1 = dec1_deg.to_radians();
    let d2 = dec2_deg.to_radians();

    let cos_sep = d1.sin()*d2.sin() + d1.cos()*d2.cos()*(ra1 - ra2).cos();
    cos_sep.clamp(-1.0, 1.0).acos().to_degrees()
}

fn chord_duration(radius_deg: f64, min_sep_deg: f64, rate_deg_s: f64) -> f64 {
    let r = radius_deg.to_radians();
    let d = min_sep_deg.to_radians();
    if d >= r || rate_deg_s <= 0.0 { return 0.0; }
    let chord = 2.0 * (r*r - d*d).sqrt();  // radians
    chord.to_degrees() / rate_deg_s
}
