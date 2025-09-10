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
//const R_SUN_KM: f64 = 695_700.0;
//const R_MOON_KM: f64 = 1_737.4;
const ISS_CHAR_LEN_M: f64 = 109.0;

const EARTH_RADIUS_KM: f64 = 6378.137;                 // WGS-84 equatorial
const EARTH_FLATTENING: f64 = 1.0 / 298.257_223_563;   // WGS-84

const SUN_MIN_ALT_DEG: f64 = -5.0;
const MOON_MIN_ALT_DEG: f64 =  5.0;

// ---------- Output model ----------
#[derive(Serialize)]
struct Transit {
    t_center_epoch: i64,       // UTC seconds since epoch
    body: String,              // "Sun" or "Moon"
    kind: String,              // "Transit" or "Near"
    min_sep_arcsec: f64,
    duration_s: f64,
    body_alt_deg: f64,
    iss_range_km: f64,
    iss_ang_size_arcsec: f64,
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
                .with_max_level(LevelFilter::Debug) // Set to DEBUG level
                .with_tag("isscore")
        );
    });
}

#[cfg(not(target_os = "android"))]
fn init_logger() {
    INIT_LOGGER.call_once(|| {
        let _ = env_logger::Builder::from_default_env()
            .filter_level(log::LevelFilter::Debug) // Set to DEBUG level
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

    // Precompute observer geocentric ECEF
    let (ox, oy, oz) = observer_ecef(lat, lon, alt_m);

    let mut t = start;
    let step = Duration::seconds(60);
    let _near_margin_deg = near_arcmin / 60.0;
    let mut events: Vec<Transit> = Vec::new();

    // Coarse sweep then refine
    while t <= end {
        for body_name in ["Sun", "Moon"] {
            let (sep_deg, radius_deg, body_alt_deg, iss_range_km) =
                sep_radius_alt_iss(&elements, &constants, t, lat, lon, ox, oy, oz, body_name);

            debug!("[predict_transits_v2] t: {}, body: {}, sep_deg: {:.2}, radius_deg: {:.2}, body_alt_deg: {:.2}, iss_range_km: {:.2}",
                t, body_name, sep_deg, radius_deg, body_alt_deg, iss_range_km);

            if body_alt_deg < SUN_MIN_ALT_DEG && body_name == "Sun" {
                debug!("[predict_transits_v2] Skipping {} due to low altitude: {:.2}", body_name, body_alt_deg);
                continue;
            }
            if body_alt_deg < MOON_MIN_ALT_DEG && body_name == "Moon" {
                debug!("[predict_transits_v2] Skipping {} due to low altitude: {:.2}", body_name, body_alt_deg);
                continue;
            }

            if sep_deg * 60.0 > near_arcmin {
                debug!("[predict_transits_v2] Skipping {} due to large separation: {:.2} arcmin", body_name, sep_deg * 60.0);
                continue;
            }

            debug!("[predict_transits_v2] Potential event detected for {} at t: {}", body_name, t);
        }
        t = t + step;
    }
    info!("[predict_transits_v2] Found {} events", events.len());
    events.sort_by_key(|e| e.t_center_epoch);
    let json = serde_json::to_string(&events).unwrap_or_else(|_| "[]".to_string());
    CString::new(json).unwrap().into_raw()
}

// ---------- Core geometry ----------

fn sep_only(
    elements: &Elements,
    constants: &Constants,
    t: DateTime<Utc>,
    lat: f64, lon: f64,
    ox: f64, oy: f64, oz: f64,
    body: &str
) -> f64 {
    let (sep, _, _, _) = sep_radius_alt_iss(elements, constants, t, lat, lon, ox, oy, oz, body);
    sep
}

fn sep_radius_alt_iss(
    elements: &Elements,
    constants: &Constants,
    t: DateTime<Utc>,
    lat: f64, lon: f64,
    ox: f64, oy: f64, oz: f64,
    body: &str
) -> (f64, f64, f64, f64) {
    // Sun/Moon RA/Dec + radius (semidiameter deg) + altitude
    let (ra_body, dec_body, radius_deg, body_alt_deg) = {
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

            let (_dist_km, ang_deg, ang_min, _ang_sec) = pa_sun::sun_distance_and_angular_size(hh, mm, ss, d as f64, mo, y, false, 0);
            let radius = (ang_deg + ang_min/60.0) / 2.0;

            let alt = alt_from_ra_dec(ra, dec, lat, lon, t);
            (ra, dec, radius, alt)
        } else {
            let (ra_h, ra_m, ra_s, dec_d, dec_m, dec_s, _el, _par) =
                pa_moon::precise_position_of_moon(hh, mm, ss, false, 0, d as f64, mo, y);
            let ra = hms_to_deg(ra_h, ra_m, ra_s);
            let dec = dms_to_deg(dec_d, dec_m, dec_s);

            let (_dist_km, ang_deg, ang_min, ang_sec, _hp_deg, _hp_min) =
                pa_moon::moon_dist_ang_diam_hor_parallax(hh, mm, ss, false, 0, d as f64, mo, y);
            let radius = (ang_deg + ang_min/60.0 + ang_sec/3600.0) / 2.0;

            let alt = alt_from_ra_dec(ra, dec, lat, lon, t);
            (ra, dec, radius, alt)
        }
    };

    // ISS topocentric RA/Dec + range
    let (iss_ra, iss_dec, iss_range_km) = iss_topocentric(elements, constants, t, lat, lon, ox, oy, oz);

    // Separation
    let sep = angular_separation_deg(iss_ra, iss_dec, ra_body, dec_body);

    (sep, radius_deg, body_alt_deg, iss_range_km)
}

// ---------- ISS propagation & frames ----------

fn iss_topocentric(
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
    // Simple GMST (degrees)
    let a = ((14 - month as i32) / 12) as i32;
    let y = year + 4800 - a;
    let m = month as i32 + 12*a - 3;
    let jdn = day as i32 + ((153*m + 2)/5) + 365*y + y/4 - y/100 + y/400 - 32045;
    let dayfrac = (hour as f64 + (minute as f64)/60.0 + second/3600.0) / 24.0;
    let jd = jdn as f64 + dayfrac;
    let d = jd - 2451545.0;
    let t = d / 36525.0;
    let gmst = 280.46061837 + 360.98564736629*d + 0.000387933*t*t - t*t*t/38710000.0;
    unwind_deg(gmst)
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
    cos_sep.acos().to_degrees()
}

fn estimate_rate<F: Fn(DateTime<Utc>) -> f64>(f: F, t0: DateTime<Utc>, dt_s: f64) -> f64 {
    let before = f(t0 - Duration::milliseconds((dt_s*1000.0) as i64));
    let after  = f(t0 + Duration::milliseconds((dt_s*1000.0) as i64));
    (after - before).abs() / (2.0*dt_s)
}

fn chord_duration(radius_deg: f64, min_sep_deg: f64, rate_deg_s: f64) -> f64 {
    let r = radius_deg.to_radians();
    let d = min_sep_deg.to_radians();
    if d >= r || rate_deg_s <= 0.0 { return 0.0; }
    let chord = 2.0 * (r*r - d*d).sqrt();  // radians
    chord.to_degrees() / rate_deg_s
}

fn refine_minimum<F: Fn(DateTime<Utc>) -> f64>(f: F, t_guess: DateTime<Utc>, window_s: i64, step_s: f64) -> (DateTime<Utc>, f64) {
    let mut best_t = t_guess;
    let mut best_v = f(t_guess);
    let steps = (2.0*window_s as f64/step_s).round() as i64;
    for i in 0..=steps {
        let t = t_guess - Duration::seconds(window_s) + Duration::milliseconds((i as f64 * step_s * 1000.0) as i64);
        let v = f(t);
        if v < best_v {
            best_v = v;
            best_t = t;
        }
    }
    (best_t, best_v)
}
