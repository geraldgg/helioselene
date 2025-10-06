use std::ffi::{CStr, CString};
use std::os::raw::c_char;

// Import from the isscore library
use isscore::{predict_transits, free_json};

#[derive(Debug, serde::Deserialize)]
#[allow(dead_code)]
struct Event {
    time_utc: String,
    body: String,
    separation_arcmin: f64,
    target_radius_arcmin: f64,
    kind: String,  // "transit", "reachable", etc.
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

#[test]
fn test_predict_transits_paris() {
    // Test the FFI function with Paris coordinates
    let tle1 = CString::new("1 25544U 98067A   25278.49802050  .00011384  00000+0  20935-3 0  9990").unwrap();
    let tle2 = CString::new("2 25544  51.6327 120.3420 0000884 206.2421 153.8523 15.49697304532279").unwrap();
    
    // Paris coordinates
    let lat = 48.8566;
    let lon = 2.3522;
    let alt_m = 35.0;
    
    // Oct 5-6, 2025 (1 day window)
    let start_epoch = 1759622400i64;
    let end_epoch = start_epoch + 86400;
    let max_distance_km = 35.0;
    
    let json_ptr = unsafe {
        predict_transits(
            tle1.as_ptr(),
            tle2.as_ptr(),
            lat,
            lon,
            alt_m,
            start_epoch,
            end_epoch,
            max_distance_km,
        )
    };
    
    assert!(!json_ptr.is_null(), "FFI should return non-null pointer");
    
    // Parse JSON result
    let json_str = unsafe { CStr::from_ptr(json_ptr).to_string_lossy() };
    println!("Transit JSON: {}", json_str);
    
    let events: Result<Vec<Event>, _> = serde_json::from_str(&json_str);
    assert!(events.is_ok(), "Should return valid JSON: {}", json_str);
    
    let events = events.unwrap();
    println!("Found {} transit events", events.len());
    
    // Validate event properties
    for (i, event) in events.iter().enumerate() {
        println!("Event {}: kind={}, alt={:.2}°, duration={:.1}s, distance={:.1}km", 
                 i+1, event.kind, event.sat_alt_deg, event.duration_s, event.sat_distance_km);
        
        assert!(event.sat_alt_deg >= 0.0 && event.sat_alt_deg <= 90.0, 
                "Elevation should be 0-90 degrees");
        assert!(event.duration_s >= 0.0, "Duration should be non-negative");
        assert!(event.sat_distance_km > 0.0, "Distance should be positive");
        assert!(event.sat_az_deg >= 0.0 && event.sat_az_deg < 360.0, 
                "Azimuth should be 0-360 degrees");
    }
    
    // Clean up
    unsafe { free_json(json_ptr as *mut c_char) };
}

#[test]
fn test_predict_transits_north_pole() {
    // Test with extreme coordinates (North Pole)
    let tle1 = CString::new("1 25544U 98067A   25278.49802050  .00011384  00000+0  20935-3 0  9990").unwrap();
    let tle2 = CString::new("2 25544  51.6327 120.3420 0000884 206.2421 153.8523 15.49697304532279").unwrap();
    
    let json_ptr = unsafe {
        predict_transits(
            tle1.as_ptr(),
            tle2.as_ptr(),
            89.9,  // Near North Pole
            0.0,
            0.0,
            1759622400i64,
            1759622400i64 + 86400,
            35.0,
        )
    };
    
    assert!(!json_ptr.is_null());
    
    let json_str = unsafe { CStr::from_ptr(json_ptr).to_string_lossy() };
    let events: Result<Vec<Event>, _> = serde_json::from_str(&json_str);
    assert!(events.is_ok(), "Should return valid JSON even for edge cases");
    
    println!("North Pole: Found {} events", events.unwrap().len());
    
    unsafe { free_json(json_ptr as *mut c_char) };
}

#[test]
fn test_predict_transits_equator() {
    // Test at the equator
    let tle1 = CString::new("1 25544U 98067A   25278.49802050  .00011384  00000+0  20935-3 0  9990").unwrap();
    let tle2 = CString::new("2 25544  51.6327 120.3420 0000884 206.2421 153.8523 15.49697304532279").unwrap();
    
    let json_ptr = unsafe {
        predict_transits(
            tle1.as_ptr(),
            tle2.as_ptr(),
            0.0,   // Equator
            0.0,   // Prime meridian
            0.0,
            1759622400i64,
            1759622400i64 + 86400,
            35.0,
        )
    };
    
    assert!(!json_ptr.is_null());
    
    let json_str = unsafe { CStr::from_ptr(json_ptr).to_string_lossy() };
    let events: Result<Vec<Event>, _> = serde_json::from_str(&json_str);
    assert!(events.is_ok());
    
    println!("Equator: Found {} events", events.unwrap().len());
    
    unsafe { free_json(json_ptr as *mut c_char) };
}

#[test]
fn test_predict_transits_short_window() {
    // Test with a very short time window (1 hour)
    let tle1 = CString::new("1 25544U 98067A   25278.49802050  .00011384  00000+0  20935-3 0  9990").unwrap();
    let tle2 = CString::new("2 25544  51.6327 120.3420 0000884 206.2421 153.8523 15.49697304532279").unwrap();
    
    let start_epoch = 1759622400i64;
    let end_epoch = start_epoch + 3600;  // Just 1 hour
    
    let json_ptr = unsafe {
        predict_transits(
            tle1.as_ptr(),
            tle2.as_ptr(),
            48.8566,
            2.3522,
            35.0,
            start_epoch,
            end_epoch,
            35.0,
        )
    };
    
    assert!(!json_ptr.is_null());
    
    let json_str = unsafe { CStr::from_ptr(json_ptr).to_string_lossy() };
    let events: Result<Vec<Event>, _> = serde_json::from_str(&json_str);
    assert!(events.is_ok());
    
    println!("1-hour window: Found {} events", events.unwrap().len());
    
    unsafe { free_json(json_ptr as *mut c_char) };
}

#[test]
fn test_predict_transits_long_window() {
    // Test with a longer time window (7 days)
    let tle1 = CString::new("1 25544U 98067A   25278.49802050  .00011384  00000+0  20935-3 0  9990").unwrap();
    let tle2 = CString::new("2 25544  51.6327 120.3420 0000884 206.2421 153.8523 15.49697304532279").unwrap();
    
    let start_epoch = 1759622400i64;
    let end_epoch = start_epoch + (7 * 86400);  // 7 days
    
    let json_ptr = unsafe {
        predict_transits(
            tle1.as_ptr(),
            tle2.as_ptr(),
            48.8566,
            2.3522,
            35.0,
            start_epoch,
            end_epoch,
            35.0,
        )
    };
    
    assert!(!json_ptr.is_null());
    
    let json_str = unsafe { CStr::from_ptr(json_ptr).to_string_lossy() };
    let events: Result<Vec<Event>, _> = serde_json::from_str(&json_str);
    
    if let Err(e) = &events {
        println!("JSON parsing error: {}", e);
        println!("JSON string: {}", json_str);
    }
    
    assert!(events.is_ok());
    
    let events = events.unwrap();
    println!("7-day window: Found {} events", events.len());
    
    // With ISS orbiting ~15.5 times per day, we should see multiple transits over 7 days
    // (though many may not meet visibility criteria)
    
    unsafe { free_json(json_ptr as *mut c_char) };
}
