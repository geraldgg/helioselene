#!/usr/bin/env python3
"""
Find ISS transits and near-misses against the Sun and Moon for the next 14 days.

Features
- Fetches latest ISS TLE (Celestrak) and uses Skyfield for accurate propagation
- Computes apparent angular separation to Sun and Moon from an observer location
- Scans ISS passes (altitude above a threshold) and refines to find closest approach
- Classifies events as:
  - transit: ISS centerline passes across the solar/lunar disc (separation <= apparent radius)
  - near: closest approach within a configurable margin (default 0.5 deg) outside the disc
- Prints a simple table and optional JSON output

Dependencies
- skyfield
- numpy
- requests

Install (examples)
  pip install skyfield numpy requests

Usage
  python iss_transits.py --lat 48.8566 --lon 2.3522 --elev 35 \
      --days 14 --alt-min 5 --near-margin-deg 0.5 --json

Notes
- Skyfield will download planetary ephemerides on first run (~100 MB, once)
- Times are printed in UTC by default; use --timezone to localize output
- This is an approximation similar in spirit to transit-finder; for production-quality maps/widths,
  further geometric modeling of the ISS silhouette and centerline mapping is needed.
"""
from __future__ import annotations

import argparse
import dataclasses
import json
import math
import time
from datetime import datetime, timedelta, timezone
from typing import Iterable, List, Optional, Tuple

import numpy as np
import requests
from skyfield.api import Loader, EarthSatellite, wgs84
import concurrent.futures
from functools import lru_cache
import os

# Simple logging helper
def _log(verbose: bool, msg: str):
    if verbose:
        print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)

def _log_timing(verbose: bool, msg: str, elapsed_s: float):
    if verbose:
        print(f"[{time.strftime('%H:%M:%S')}] {msg} (took {elapsed_s:.2f}s)", flush=True)

# Constants
CELESTRAK_TLE_URL_ISS = "https://celestrak.org/NORAD/elements/gp.php?CATNR=25544&FORMAT=TLE"
CELESTRAK_TLE_URL_TG = "https://celestrak.org/NORAD/elements/gp.php?CATNR=48274&FORMAT=TLE"  # Tiangong
CELESTRAK_TLE_URL_HUBBLE = "https://celestrak.org/NORAD/elements/gp.php?CATNR=20580&FORMAT=TLE"  # Hubble Space Telescope
ISS_NAME = "ISS (ZARYA)"
TIANGONG_NAME = "TIANGONG"
HUBBLE_NAME = "HUBBLE SPACE TELESCOPE"
SUN_RADIUS_KM = 696_340.0
MOON_RADIUS_KM = 1_737.4

# Default parameters
DEFAULT_DAYS = 10
DEFAULT_COARSE_STEP_S = 20.0
DEFAULT_FINE_STEP_S = 1.0
DEFAULT_REFINEMENT_WINDOW_S = 60.0  # Reduced from 120s to 60s for faster processing
DEFAULT_ALT_MIN_DEG = 5.0
DEFAULT_NEAR_MARGIN_DEG = 0.5


def fetch_tle(url: str) -> tuple[str, str]:
    """Fetch the latest TLE for a satellite from Celestrak. Returns (line1, line2)."""
    resp = requests.get(url, timeout=20)
    resp.raise_for_status()
    lines = [l.strip() for l in resp.text.splitlines() if l.strip()]
    if len(lines) >= 3 and not lines[0].startswith("1 "):
        return lines[1], lines[2]
    l1 = next(l for l in lines if l.startswith("1 "))
    l2 = next(l for l in lines if l.startswith("2 "))
    return l1, l2


@dataclasses.dataclass
class Event:
    dt_utc: datetime
    body: str  # 'Sun' or 'Moon'
    separation_deg: float
    target_radius_deg: float
    kind: str  # 'transit' or 'near'
    iss_alt_deg: float
    target_alt_deg: float
    lat: float = None
    lon: float = None
    elev: float = None
    distance_km: float = None
    sat_name: str = None  # Added satellite name
    speed_deg_per_s: float = None  # Apparent angular speed at closest approach (deg/s)
    duration_s: float = None       # Estimated transit duration when in front of disc (s)

    def to_dict(self):
        d = {
            "time_utc": self.dt_utc.isoformat().replace("+00:00", "Z"),
            "body": self.body,
            "separation_deg": round(self.separation_deg, 6),
            "target_radius_deg": round(self.target_radius_deg, 6),
            "kind": self.kind,
            "iss_alt_deg": round(self.iss_alt_deg, 3),
            "target_alt_deg": round(self.target_alt_deg, 3),
        }
        if self.lat is not None:
            d["lat"] = round(self.lat, 6)
            d["lon"] = round(self.lon, 6)
            d["elev"] = round(self.elev, 1)
            d["distance_km"] = round(self.distance_km, 2)
        if self.sat_name is not None:
            d["satellite"] = self.sat_name
        if self.speed_deg_per_s is not None:
            d["speed_deg_per_s"] = round(self.speed_deg_per_s, 6)
        if self.duration_s is not None:
            d["duration_s"] = round(self.duration_s, 3)
        return d


def angular_radius_deg(physical_radius_km: float, distance_km) -> float | np.ndarray:
    # Support scalar or numpy array distances; compute arcsin(R/d) in degrees
    return np.degrees(np.arcsin(np.minimum(1.0, physical_radius_km / np.asarray(distance_km))))


def angle_between(u: np.ndarray, v: np.ndarray) -> float:
    """Angle between vectors in radians. Optimized version.
    u, v shape (..., 3)
    """
    # Optimized: avoid double normalization by computing norms once
    u_norm = np.linalg.norm(u, axis=-1, keepdims=True)
    v_norm = np.linalg.norm(v, axis=-1, keepdims=True)
    
    # Avoid division by computing dot product directly
    dot = np.sum(u * v, axis=-1) / (u_norm.squeeze(-1) * v_norm.squeeze(-1))
    dot = np.clip(dot, -1.0, 1.0)
    return np.arccos(dot)


def find_pass_intervals(altitudes_deg: np.ndarray, times: np.ndarray, alt_min: float) -> List[Tuple[int, int]]:
    """Return list of (start_idx, end_idx) for contiguous intervals where altitudes exceed alt_min.
    Inclusive indices. Optimized vectorized version.
    """
    above = altitudes_deg >= alt_min
    if not np.any(above):
        return []
    
    # Vectorized approach: find transitions
    diff = np.diff(above.astype(int), prepend=0, append=0)
    starts = np.where(diff == 1)[0]  # Rising edges (enter pass)
    ends = np.where(diff == -1)[0] - 1  # Falling edges (exit pass) 
    
    return list(zip(starts, ends))


def refine_minimum(ts, sat, eph, observer, t_center, window_s: float, step_s: float, body: str) -> Tuple[datetime, float, float, float, float]:
    """Refine minimum separation around t_center for a given body.

    Returns (dt_utc, separation_deg, target_radius_deg, iss_alt_deg, target_alt_deg)
    """
    n_before = int(window_s // step_s)
    # Build a list of datetimes around the center with fixed step in seconds
    offsets = np.arange(-n_before, n_before + 1, dtype=float)
    times = ts.from_datetimes([
        t_center.utc_datetime() + timedelta(seconds=float(k * step_s))
        for k in offsets
    ])

    # Choose body and radius first to avoid repeated conditionals
    if body == 'Sun':
        b = eph['sun']
        radius_km = SUN_RADIUS_KM
    else:
        b = eph['moon']
        radius_km = MOON_RADIUS_KM

    # Positions - vectorized computation
    sat_topo = (sat - observer).at(times)
    sat_pos = sat_topo.position.km.T  # shape (N, 3)
    sat_range_km = np.linalg.norm(sat_pos, axis=-1)
    
    # Use geocentric observer for Sun/Moon - vectorized
    obs = eph['earth'] + observer
    body_pos = obs.at(times).observe(b).position.km.T

    # Vectorized separations computation
    sep_rad = angle_between(sat_pos, body_pos)

    # Find minimum separation index
    i_min = int(np.argmin(sep_rad))
    
    # Only compute altitudes and distances for the minimum point (not the entire array)
    t_min_single = times[i_min:i_min+1]  # Single time for efficient computation
    
    # Altitudes at minimum point only - more efficient direct computation
    sat_alt_min, _, _ = (sat - observer).at(t_min_single).altaz()
    tgt_alt_min, _, _ = obs.at(t_min_single).observe(b).apparent().altaz()
    
    # Distance to compute angular radius at minimum point only
    body_distance_km = np.linalg.norm(body_pos[i_min])
    tgt_radius_deg = angular_radius_deg(radius_km, body_distance_km)

    # Extract results
    t_min = times[i_min].utc_datetime().replace(tzinfo=timezone.utc)
    sep_min_deg = math.degrees(float(sep_rad[i_min]))
    iss_alt_deg = float(sat_alt_min.degrees[0])
    target_alt_deg = float(tgt_alt_min.degrees[0])
    
    # Attach the range for downstream fast radius check
    refine_minimum.iss_range_km = float(sat_range_km[i_min])

    return t_min, sep_min_deg, tgt_radius_deg, iss_alt_deg, target_alt_deg


def haversine_km(lat1, lon1, lat2, lon2):
    """Great-circle distance between two points (degrees) in kilometers."""
    R = 6371.0
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi/2)**2 + math.cos(phi1)*math.cos(phi2)*math.sin(dlambda/2)**2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


@lru_cache(maxsize=10000)
def get_elevation(lat: float, lon: float) -> float:
    """Query Open-Elevation API for elevation in meters. Returns 0.0 on failure. Cached."""
    try:
        url = f"https://api.open-elevation.com/api/v1/lookup?locations={lat},{lon}"
        resp = requests.get(url, timeout=10)
        resp.raise_for_status()
        data = resp.json()
        if "results" in data and data["results"]:
            return float(data["results"][0]["elevation"])
    except Exception:
        pass
    return 0.0


def compute_events(
    lat: float, lon: float, elev_m: float, days: int = DEFAULT_DAYS,
    alt_min_deg: float = DEFAULT_ALT_MIN_DEG,
    coarse_step_s: float = DEFAULT_COARSE_STEP_S,
    fine_step_s: float = DEFAULT_FINE_STEP_S,
    refine_window_s: float = DEFAULT_REFINEMENT_WINDOW_S,
    near_margin_deg: float = DEFAULT_NEAR_MARGIN_DEG,
    max_distance_km: float = 0.0,
    grid_step_km: float = 2.0,
    grid_elev_mode: str = "base",
    workers: int | None = None,
    verbose: bool = False,
    satellites: list = None,
) -> List[Event]:
    script_start = time.time()
    if satellites is None:
        satellites = [(ISS_NAME, CELESTRAK_TLE_URL_ISS)]
    
    # Load ephemerides and timescale
    eph_start = time.time()
    _log(verbose, f"Loading ephemerides and timescale ...")
    load = Loader("~/.skyfield-data")
    ts = load.timescale()
    eph = load("de421.bsp")
    eph_elapsed = time.time() - eph_start
    _log_timing(verbose, "Ephemerides and timescale loaded", eph_elapsed)

    # Fetch TLEs in parallel
    tle_start = time.time()
    _log(verbose, f"Preparing observer and fetching TLEs in parallel ...")
    observer = wgs84.latlon(latitude_degrees=lat, longitude_degrees=lon, elevation_m=elev_m)
    obs = eph['earth'] + observer

    # Fetch TLEs in parallel for faster initialization
    def fetch_tle_with_name(name_url_pair):
        name, url = name_url_pair
        _log(verbose, f"Fetching TLE for {name} ...")
        l1, l2 = fetch_tle(url)
        return (name, l1, l2)

    sats = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(len(satellites), 5)) as ex:
        futures = [ex.submit(fetch_tle_with_name, (name, url)) for name, url in satellites]
        for fut in concurrent.futures.as_completed(futures):
            name, l1, l2 = fut.result()
            sats.append((name, EarthSatellite(l1, l2, name, ts)))
            _log(verbose, f"Created satellite object for {name}")
    
    # Sort satellites by name for consistent ordering
    sats.sort(key=lambda x: x[0])
    tle_elapsed = time.time() - tle_start
    _log_timing(verbose, f"TLE fetching and satellite creation completed", tle_elapsed)

    # Build time grid - optimized for fewer allocations
    grid_start = time.time()
    t0 = datetime.now(timezone.utc)
    t1 = t0 + timedelta(days=days)
    n_steps = int(((t1 - t0).total_seconds() // coarse_step_s) + 1)
    _log(verbose, f"Building time grid: {n_steps} samples over {days} days (step {coarse_step_s}s)")
    
    # More efficient time array creation
    time_seconds = np.arange(n_steps, dtype=float) * coarse_step_s
    times = ts.from_datetimes([t0 + timedelta(seconds=float(s)) for s in time_seconds])
    
    grid_elapsed = time.time() - grid_start
    _log_timing(verbose, "Time grid built", grid_elapsed)

    events: List[Event] = []

    # Build pass jobs for all satellites - optimized batch processing
    pass_analysis_start = time.time()
    jobs = []
    
    for sat_name, sat in sats:
        sat_computation_start = time.time()
        _log(verbose, f"Computing {sat_name} altitude to find visible passes ...")
        
        # More efficient altitude computation: compute topocentric directly
        sat_topocentric = (sat - observer).at(times)
        alt_deg, az_deg, distance_km = sat_topocentric.altaz()
        alt_degrees = alt_deg.degrees
        
        sat_computation_elapsed = time.time() - sat_computation_start
        _log_timing(verbose, f"{sat_name} altitude computation", sat_computation_elapsed)
        
        interval_start = time.time()
        intervals = find_pass_intervals(alt_degrees, times, alt_min_deg)
        interval_elapsed = time.time() - interval_start
        _log_timing(verbose, f"{sat_name} pass interval detection", interval_elapsed)
        _log(verbose, f"Found {len(intervals)} visible {sat_name} pass interval(s) above {alt_min_deg}°")

        for i0, i1 in intervals:
            t_segment = times[i0:i1 + 1]

            def make_job(sat_name=sat_name, sat=sat, t_segment=t_segment):
                def _run_pass():
                    pass_start = time.time()
                    local_events: List[Event] = []
                    # Compute Sun/Moon positions only for this time segment (more efficient than pre-computing all)
                    obs_start = time.time()
                    obs = eph['earth'] + observer
                    sun_vec_seg = obs.at(t_segment).observe(eph['sun']).position.km.T
                    moon_vec_seg = obs.at(t_segment).observe(eph['moon']).position.km.T
                    sat_vec = (sat - observer).at(t_segment).position.km.T
                    obs_elapsed = time.time() - obs_start
                    
                    angle_start = time.time()
                    sep_sun = angle_between(sat_vec, sun_vec_seg)
                    sep_moon = angle_between(sat_vec, moon_vec_seg)
                    angle_elapsed = time.time() - angle_start

                    # Initialize timing variables to avoid UnboundLocalError
                    total_refine_elapsed = 0.0
                    total_speed_elapsed = 0.0

                    for body, sep_arr in (("Sun", sep_sun), ("Moon", sep_moon)):
                        body_start = time.time()
                        j_min = int(np.argmin(sep_arr))
                        # Quick pre-filter: skip if minimum separation is too large
                        min_sep_rad = float(sep_arr[j_min])
                        min_sep_deg = math.degrees(min_sep_rad)
                        
                        # Rough radius estimate for quick filtering (assume ~400km satellite distance)
                        if body == 'Sun':
                            rough_radius_deg = math.degrees(math.atan(SUN_RADIUS_KM / 150_000_000))  # ~0.53 deg
                            max_interesting_sep = rough_radius_deg + near_margin_deg + 2.0  # +2° buffer
                        else:
                            rough_radius_deg = math.degrees(math.atan(MOON_RADIUS_KM / 384_400))  # ~0.26 deg  
                            max_interesting_sep = rough_radius_deg + near_margin_deg + 2.0  # +2° buffer
                        
                        # Skip refinement if clearly too far away
                        if min_sep_deg > max_interesting_sep:
                            continue
                        
                        refine_start = time.time()
                        t_center = t_segment[j_min]
                        t_min, sep_min_deg, tgt_rad_deg, sat_alt_deg, tgt_alt_deg = refine_minimum(
                            ts, sat, eph, observer, t_center, refine_window_s, fine_step_s, body
                        )
                        refine_elapsed = time.time() - refine_start
                        total_refine_elapsed += refine_elapsed
                        sat_range_km = getattr(refine_minimum, 'iss_range_km', None)
                        
                        # Quick classification to avoid expensive speed calculation if not needed
                        if sep_min_deg <= tgt_rad_deg:
                            kind = "transit"
                        elif sep_min_deg <= (tgt_rad_deg + near_margin_deg):
                            kind = "near"
                        else:
                            kind = None
                        # Fast radius reachability check (parallax approximation): d ≈ θ * range
                        if not kind and max_distance_km > 0 and sat_range_km is not None:
                            sep_rad = math.radians(sep_min_deg)
                            required_km = sep_rad * float(sat_range_km)
                            if required_km <= max_distance_km and tgt_alt_deg >= 0 and sat_alt_deg >= alt_min_deg:
                                kind = "reachable"
                        
                        speed_elapsed = 0.0  # Initialize to avoid UnboundLocalError
                        # Only compute expensive speed/duration if we have a valid event
                        if kind and tgt_alt_deg >= 0 and sat_alt_deg >= alt_min_deg:
                            speed_start = time.time()
                            # Estimate instantaneous angular speed around t_min using central difference
                            t_minus = ts.from_datetimes([t_min - timedelta(seconds=fine_step_s)])
                            t_plus = ts.from_datetimes([t_min + timedelta(seconds=fine_step_s)])
                            # Positions at t_minus/t_plus
                            sat_vec_m = (sat - observer).at(t_minus).position.km.T[0]
                            sat_vec_p = (sat - observer).at(t_plus).position.km.T[0]
                            if body == 'Sun':
                                b = eph['sun']
                            else:
                                b = eph['moon']
                            obs_e = eph['earth'] + observer
                            body_vec_m = obs_e.at(t_minus).observe(b).position.km.T[0]
                            body_vec_p = obs_e.at(t_plus).observe(b).position.km.T[0]
                            sep_m = float(angle_between(sat_vec_m, body_vec_m))
                            sep_p = float(angle_between(sat_vec_p, body_vec_p))
                            speed_rad_per_s = (sep_p - sep_m) / (2.0 * fine_step_s)
                            speed_deg_per_s = abs(math.degrees(speed_rad_per_s))
                            speed_elapsed = time.time() - speed_start
                            total_speed_elapsed += speed_elapsed
                            
                            ev = Event(
                                dt_utc=t_min,
                                body=body,
                                separation_deg=sep_min_deg,
                                target_radius_deg=tgt_rad_deg,
                                kind=kind,
                                iss_alt_deg=sat_alt_deg,
                                target_alt_deg=tgt_alt_deg,
                                sat_name=sat_name,
                                speed_deg_per_s=speed_deg_per_s,
                            )
                            # Duration estimate: time while separation <= target_radius (approx 2*radius/speed)
                            if speed_deg_per_s > 0 and sep_min_deg <= tgt_rad_deg:
                                ev.duration_s = 2.0 * tgt_rad_deg / speed_deg_per_s
                            if kind == "reachable" and sat_range_km is not None:
                                ev.distance_km = round(math.radians(sep_min_deg) * float(sat_range_km), 3)
                            local_events.append(ev)
                    
                    pass_elapsed = time.time() - pass_start
                    if verbose and pass_elapsed > 0.1:  # Only log slow passes
                        print(f"    Pass timing: obs={obs_elapsed:.3f}s, angles={angle_elapsed:.3f}s, refine={total_refine_elapsed:.3f}s, speed={total_speed_elapsed:.3f}s, total={pass_elapsed:.3f}s", flush=True)
                    return local_events
                return _run_pass
            jobs.append(make_job())

    pass_setup_elapsed = time.time() - pass_analysis_start
    _log_timing(verbose, f"Pass analysis and job setup completed", pass_setup_elapsed)

    if verbose:
        _log(True, f"Running {len(jobs)} pass refinements in parallel (workers={workers or 'auto'}) ...")

    # Execute jobs in thread pool
    refinement_start = time.time()
    with concurrent.futures.ThreadPoolExecutor(max_workers=(None if not workers or workers <= 0 else workers)) as ex:
        futures = [ex.submit(job) for job in jobs]
        completed = 0
        last_progress_time = time.time()
        for fut in concurrent.futures.as_completed(futures):
            completed += 1
            if verbose and completed % max(1, len(jobs)//10) == 0:
                current_time = time.time()
                batch_time = current_time - last_progress_time
                rate = (len(jobs)//10) / batch_time if batch_time > 0 else 0
                print(f"  Progress: {completed}/{len(jobs)} passes refined ({rate:.1f} passes/s)", flush=True)
                last_progress_time = current_time
            events.extend(fut.result())

    refinement_elapsed = time.time() - refinement_start
    _log_timing(verbose, f"Pass refinement completed ({len(events)} events found)", refinement_elapsed)

    # Sort by time
    sort_start = time.time()
    events.sort(key=lambda e: e.dt_utc)
    sort_elapsed = time.time() - sort_start
    _log_timing(verbose, "Event sorting completed", sort_elapsed)

    # If fast radius mode, skip grid and return
    if max_distance_km > 0:
        _log(verbose, "Fast radius check enabled; skipping grid search")
        script_elapsed = time.time() - script_start
        _log_timing(verbose, "TOTAL SCRIPT TIME", script_elapsed)
        return events

    # Build search grid (if requested)
    grid_build_start = time.time()
    if max_distance_km <= 0:
        search_points = [(lat, lon, elev_m, 0.0)]
        _log(verbose, "Grid search disabled; using only base location")
    else:
        search_points = []
        n_steps_radial = int(max_distance_km // grid_step_km) + 1
        cos_lat = math.cos(math.radians(lat))
        for d in range(n_steps_radial + 1):
            r = d * grid_step_km
            n_theta = max(8, int(2 * math.pi * max(r, grid_step_km) / grid_step_km)) if r > 0 else 1
            for k in range(n_theta):
                theta = 2 * math.pi * k / n_theta
                dlat = (r / 111.32) * math.cos(theta)
                dlon = 0 if cos_lat == 0 else (r / (111.32 * cos_lat)) * math.sin(theta)
                plat = lat + dlat
                plon = lon + dlon
                if grid_elev_mode == "lookup" and r > 0:
                    pelev = get_elevation(round(plat, 5), round(plon, 5))
                else:
                    pelev = elev_m
                search_points.append((plat, plon, pelev, r))
        _log(verbose, f"Built grid with {len(search_points)} points within {max_distance_km} km (step {grid_step_km} km, elev mode {grid_elev_mode})")
    
    grid_build_elapsed = time.time() - grid_build_start
    _log_timing(verbose, f"Grid construction completed ({len(search_points)} points)", grid_build_elapsed)

    # Evaluate grid
    def evaluate_point(plat, plon, pelev, pdist, t_segment):
        local_best = {}
        observer_p = wgs84.latlon(latitude_degrees=plat, longitude_degrees=plon, elevation_m=pelev)
        obs_p = eph['earth'] + observer_p
        sun_vec_p = obs_p.at(t_segment).observe(eph['sun']).position.km.T
        moon_vec_p = obs_p.at(t_segment).observe(eph['moon']).position.km.T
        iss_vec_p = (sat - observer_p).at(t_segment).position.km.T
        sep_sun_p = angle_between(iss_vec_p, sun_vec_p)
        sep_moon_p = angle_between(iss_vec_p, moon_vec_p)
        for body, sep_arr in (("Sun", sep_sun_p), ("Moon", sep_moon_p)):
            j_min = int(np.argmin(sep_arr))
            t_center = t_segment[j_min]
            t_min, sep_min_deg, tgt_rad_deg, iss_alt_deg, tgt_alt_deg = refine_minimum(
                ts, sat, eph, observer_p, t_center, refine_window_s, fine_step_s, body
            )
            if sep_min_deg <= tgt_rad_deg:
                kind = "transit"
            elif sep_min_deg <= (tgt_rad_deg + near_margin_deg):
                kind = "near"
            else:
                continue
            if tgt_alt_deg < 0 or iss_alt_deg < alt_min_deg:
                continue
            key = (t_min, body, kind)
            if key not in local_best or pdist < local_best[key]["distance_km"]:
                local_best[key] = {
                    "event": Event(
                        dt_utc=t_min,
                        body=body,
                        separation_deg=sep_min_deg,
                        target_radius_deg=tgt_rad_deg,
                        kind=kind,
                        iss_alt_deg=iss_alt_deg,
                        target_alt_deg=tgt_alt_deg,
                    ),
                    "lat": plat,
                    "lon": plon,
                    "elev": pelev,
                    "distance_km": pdist,
                }
        return local_best

    grid_events: List[Event] = []
    grid_eval_start = time.time()
    for idx, (i0, i1) in enumerate(intervals, start=1):
        t_segment = times[i0:i1 + 1]
        _log(verbose, f"Evaluating grid for pass {idx}/{len(intervals)} across {len(search_points)} points ...")
        bests = {}
        completed = 0
        with concurrent.futures.ThreadPoolExecutor(max_workers=(None if not workers or workers <= 0 else workers)) as ex:
            futures = [ex.submit(evaluate_point, plat, plon, pelev, pdist, t_segment) for (plat, plon, pelev, pdist) in search_points]
            for fut in concurrent.futures.as_completed(futures):
                completed += 1
                if verbose and completed % max(1, len(search_points)//10) == 0:
                    print(f"  Grid progress: {completed}/{len(search_points)} points", flush=True)
                local_best = fut.result()
                for key, val in local_best.items():
                    if key not in bests or val["distance_km"] < bests[key]["distance_km"]:
                        bests[key] = val
        for v in bests.values():
            e = v["event"]
            e.lat = v["lat"]
            e.lon = v["lon"]
            e.elev = v["elev"]
            e.distance_km = v["distance_km"]
            grid_events.append(e)
        _log(verbose, f"  Found {len(bests)} grid event(s) for this pass")

    grid_eval_elapsed = time.time() - grid_eval_start
    _log_timing(verbose, f"Grid evaluation completed ({len(grid_events)} grid events)", grid_eval_elapsed)

    # Merge grid events (they include base if grid disabled)
    final_sort_start = time.time()
    grid_events.sort(key=lambda e: e.dt_utc)
    final_sort_elapsed = time.time() - final_sort_start
    _log_timing(verbose, "Final sorting completed", final_sort_elapsed)
    
    script_elapsed = time.time() - script_start
    _log_timing(verbose, "TOTAL SCRIPT TIME", script_elapsed)
    
    return grid_events


def localize(dt_utc: datetime, tz_name: Optional[str]) -> datetime:
    if not tz_name:
        return dt_utc
    try:
        import zoneinfo  # Python 3.9+
        tz = zoneinfo.ZoneInfo(tz_name)
        return dt_utc.astimezone(tz)
    except Exception:
        return dt_utc


def main():
    p = argparse.ArgumentParser(description="ISS/Tiangong/Hubble solar/lunar transit and near-pass finder")
    p.add_argument("--lat", type=float, required=True, help="Latitude in degrees (positive north)")
    p.add_argument("--lon", type=float, required=True, help="Longitude in degrees (positive east)")
    p.add_argument("--elev", type=float, default=None, help="Elevation in meters above sea level (if not set, will be auto-detected)")
    p.add_argument("--days", type=int, default=DEFAULT_DAYS, help="Days to search ahead (default 14)")
    p.add_argument("--alt-min", type=float, default=DEFAULT_ALT_MIN_DEG, help="Minimum satellite altitude (deg) to consider a pass")
    p.add_argument("--near-margin-deg", type=float, default=DEFAULT_NEAR_MARGIN_DEG, help="Margin beyond the disc radius to classify as 'near' (deg)")
    p.add_argument("--coarse-step-s", type=float, default=DEFAULT_COARSE_STEP_S, help="Coarse sampling step in seconds")
    p.add_argument("--fine-step-s", type=float, default=DEFAULT_FINE_STEP_S, help="Fine refinement step in seconds")
    p.add_argument("--refine-window-s", type=float, default=DEFAULT_REFINEMENT_WINDOW_S, help="Half-window around coarse min for refinement (seconds)")
    p.add_argument("--timezone", type=str, default=None, help="IANA timezone for display (e.g. Europe/Paris). Default: UTC")
    p.add_argument("--json", action="store_true", help="Output JSON instead of table")
    p.add_argument("--max-distance-km", type=float, default=0.0, help="Search for events within this radius (km) from your location (default: 0, only your location)")
    p.add_argument("--grid-step-km", type=float, default=2.0, help="Grid step for search (km, default 2)")
    p.add_argument("--grid-elev-mode", type=str, choices=["base", "lookup"], default="base", help="Elevation for grid points: use base elevation or lookup per point (default base)")
    p.add_argument("--workers", type=int, default=0, help="Max worker threads for grid evaluation (0=auto)")
    p.add_argument("--verbose", action="store_true", help="Print progress logs")
    p.add_argument("--satellites", type=str, default="ISS,TIANGONG,HUBBLE", help="Comma-separated list of satellites: ISS,TIANGONG,HUBBLE or any combination (default: all three)")

    args = p.parse_args()

    # Auto-detect elevation if not provided
    if args.elev is None:
        print(f"Looking up elevation for lat={args.lat}, lon={args.lon} ...", flush=True)
        args.elev = get_elevation(args.lat, args.lon)
        print(f"Using elevation: {args.elev:.1f} m", flush=True)

    sats = []
    for s in args.satellites.upper().split(","):
        s = s.strip()
        if s == "ISS":
            sats.append((ISS_NAME, CELESTRAK_TLE_URL_ISS))
        elif s == "TIANGONG":
            sats.append((TIANGONG_NAME, CELESTRAK_TLE_URL_TG))
        elif s == "HUBBLE":
            sats.append((HUBBLE_NAME, CELESTRAK_TLE_URL_HUBBLE))

    if not sats:
        print("No valid satellites selected. Use --satellites=ISS,TIANGONG,HUBBLE or any combination.")
        return

    events = compute_events(
        lat=args.lat,
        lon=args.lon,
        elev_m=args.elev,
        days=args.days,
        alt_min_deg=args.alt_min,
        coarse_step_s=args.coarse_step_s,
        fine_step_s=args.fine_step_s,
        refine_window_s=args.refine_window_s,
        near_margin_deg=args.near_margin_deg,
        max_distance_km=args.max_distance_km,
        grid_step_km=args.grid_step_km,
        grid_elev_mode=args.grid_elev_mode,
        workers=args.workers,
        verbose=args.verbose,
        satellites=sats,
    )

    if args.json:
        out = []
        for e in events:
            d = e.to_dict()
            if hasattr(e, 'sat_name'):
                d["satellite"] = e.sat_name
            if args.timezone:
                dt_local = localize(e.dt_utc, args.timezone)
                d["time_local"] = dt_local.isoformat()
            out.append(d)
        print(json.dumps(out, indent=2))
        return

    if not events:
        print("No ISS/Tiangong/Hubble solar/lunar transits or near passes found in the specified window.")
        return

    # Table output
    print("Time (UTC) / Local | Sat | Body | Kind | Sep (arcsec) | Disc Radius (arcsec) | Sat Alt (deg) | Target Alt (deg)")
    for e in events:
        sep_arcsec = e.separation_deg * 3600.0
        rad_arcsec = e.target_radius_deg * 3600.0
        dt_disp = e.dt_utc.strftime('%Y-%m-%d %H:%M:%SZ')
        if args.timezone:
            dt_local = localize(e.dt_utc, args.timezone)
            dt_disp += f" / {dt_local.strftime('%Y-%m-%d %H:%M:%S %Z')}"
        sat_disp = getattr(e, 'sat_name', 'UNKNOWN') or 'UNKNOWN'
        print(f"{dt_disp} | {sat_disp:10} | {e.body:4} | {e.kind:7} | {sep_arcsec:9.1f} | {rad_arcsec:16.1f} | {e.iss_alt_deg:11.1f} | {e.target_alt_deg:14.1f}")


if __name__ == "__main__":
    main()
