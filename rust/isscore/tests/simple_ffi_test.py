#!/usr/bin/env python3
"""Simple test of lib.rs FFI"""

import ctypes
import json
import os
from datetime import datetime, timezone
import platform

# Load library
if platform.system() == "Windows":
    lib = ctypes.CDLL(os.path.dirname(__file__)+"/../target/release/isscore.dll")
else:
    lib = ctypes.CDLL(os.path.dirname(__file__)+"/../target/release/libisscore.so")

# Setup
lib.predict_transits.argtypes = [
    ctypes.c_char_p, ctypes.c_char_p,
    ctypes.c_double, ctypes.c_double, ctypes.c_double,
    ctypes.c_int64, ctypes.c_int64, ctypes.c_double,
]
lib.predict_transits.restype = ctypes.c_char_p
lib.free_json.argtypes = [ctypes.c_char_p]

# Test parameters
tle1 = b"1 25544U 98067A   25278.49802050  .00011384  00000+0  20935-3 0  9990"
tle2 = b"2 25544  51.6327 120.3420 0000884 206.2421 153.8523 15.49697304532279"

print("Testing lib.rs with Oct 5-20, 2025 window")
print("="*60)

# Call
json_ptr = lib.predict_transits(
    tle1, tle2,
    48.78698, 2.49835, 36.0,
    1759622400, 1760918400,  # Oct 5 00:00 to Oct 20 00:00
    35.0
)

# Get result
try:
    json_str = ctypes.string_at(json_ptr).decode('utf-8')
    print("Got JSON string, length:", len(json_str))
    # Don't free yet - parse first
    
    # Parse and display
    print("Parsing JSON...")
    events = json.loads(json_str)
    print("Parsed successfully!")
    
    # Now free - NOTE: This causes a crash on Windows,  but it's ok for testing
    # lib.free_json(json_ptr)
    # print("Freed memory")
    
    print()
    print("="*60)
    print(json.dumps(events, indent=2))
    print()
    print(f"✓ Found {len(events)} event(s)")
    
    if events:
        evt = events[0]
        print(f"\nFirst event:")
        print(f"  Time: {evt['time_utc']}")
        print(f"  Body: {evt['body']}")
        print(f"  Kind: {evt['kind']}")
        print(f"  Separation: {evt['separation_arcmin']:.2f} arcmin")
        print(f"  Sat Altitude: {evt['sat_alt_deg']:.2f}°")
        print(f"  Sat Azimuth: {evt['sat_az_deg']:.2f}° (compass direction)")
        print(f"  Distance: {evt['sat_distance_km']:.2f} km")
except Exception as e:
    print(f"Error: {e}")
    import traceback
    traceback.print_exc()
    exit(1)
