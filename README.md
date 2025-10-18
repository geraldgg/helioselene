# HelioSelene

Predict when bright low‑Earth orbit satellites (ISS, Tiangong, Hubble) cross *in front of* or pass *very close to* the Sun or Moon for a chosen location and time window.

This project is a Flutter app powered by a Rust core (via FFI) plus an optional Python script for cross‑checking results.

---
## Why?
Planning a solar or lunar transit photo of the ISS (or similar craft) normally requires web tools. Helioselene lets you do it locally, offline after the first run, and compare multiple satellites quickly.

---
## Key Features
- Multiple satellites selectable (ISS, Tiangong, Hubble)
- 14‑day scan window (adjustable in code today)
- Event types: Transit, Near, Reachable (see below)
- Adjustable “near” margin (arcminutes slider)
- Fast native orbit propagation (SGP4 in Rust)
- Compact UI: tap Predict, view chronological list
- Cross‑check / experiment with included Python script

---
## Event Types (Simple)
| Type | Meaning |
|------|---------|
| Transit | Satellite center passes across Sun/Moon disc |
| Near | Misses disc but within your selected margin |
| Reachable | A bit farther, but roughly drivable (distance estimate below a built‑in threshold) |

You can increase the near margin slider to surface more candidate lines of sight.

---
## Quick Start (Flutter + Rust – Android example)
```bash
# (Optional) build native Rust library for Android ABIs
./scripts/build_rust_android.ps1

# Fetch dependencies & run app
flutter pub get
flutter run
```
The app will download TLEs on demand and show results after a short computation.

> iOS / desktop targets: Flutter project scaffolding is present; you only need to add equivalent Rust build steps for those platforms.

---
## Using the App
1. Launch the app.
2. Leave selected satellites (uncheck any you don't want).
3. Adjust near margin if you want more “Near” / “Reachable” candidates.
4. Tap “Predict next 14 days”.
5. Scroll the list – each entry shows time (UTC), satellite, Sun/Moon, event type, separation, altitude, rough duration.

( Current location & date range are fixed in code; geolocation & custom ranges are on the roadmap. )

---
## Python Validation (Optional)
```bash
pip install skyfield numpy requests
python iss_transits.py --lat 48.7868 --lon 2.4981 --elev 36 \
  --days 14 --near-margin-deg 0.5 --satellites ISS,TIANGONG --verbose
```
Use this if you want to sanity‑check or experiment quickly.

---
## Configuration Knobs (User‑Visible)
| Setting | Where | Effect |
|---------|-------|--------|
| Near margin (arcmin) | Slider in UI | Loosens / tightens “Near” boundary |
| Satellite selection | Checkboxes | Limits which TLEs are fetched |

Internal constants (edit in Rust): reachability distance, refinement buffer, altitude threshold, time steps.

---
## How It Works (One Paragraph)
For each selected satellite the app downloads the latest TLE, propagates its orbit over the chosen window at coarse steps, finds periods when it’s above a minimum altitude, refines potential alignments with the Sun/Moon near closest approach, classifies each minimum, and returns a sorted list of events. Rust handles the math; Flutter handles presentation.

---
## Troubleshooting (Condensed)
| Issue | Fix |
|-------|-----|
| Empty list | Satellite not above min altitude in window – widen window or keep default dates |
| Too few events | Increase near margin |
| Build errors after Rust edits | Re-run Rust build script, then `flutter clean && flutter run` |
| Python vs app differs | Ensure both use same start time & margin; minor differences normal |

---
## Roadmap (Short)
- User‑set start/end dates & geolocation
- Expose reachability distance in UI
- Filter Sun vs Moon
- Map / ground track preview
- iOS & Web (WASM) build scripts

---
## License
No formal license yet (private / exploratory). Add one before distribution.

---
## Contributing
Open an issue or PR with focused improvements (performance, UI polish, new satellites, better reachability model).

---
## Acknowledgements
Celestrak TLE data • SGP4 model • Skyfield (validation) • Flutter & Rust ecosystems

---
## Updating the App Icon
You already have `flutter_launcher_icons` configured in `pubspec.yaml`:
```
flutter_launcher_icons:
  android:
    generate: true
  ios:
    generate: true
  windows:
    generate: true
  macos:
    generate: true
  image_path: "app_icon.png"
```
Follow these steps to make Flutter use your new icon everywhere:

1. Replace the source image
   - Put your new base icon file at the project root as `app_icon.png` (or change `image_path` accordingly). Ideal: 1024x1024 PNG, square, transparent background if possible.
   - Keep important graphic elements centered; avoid very fine details (downscaling).

2. (Optional) Configure adaptive Android icon
   - If you want a proper adaptive icon (foreground + background), edit the `flutter_launcher_icons` section:
     ```yaml
     flutter_launcher_icons:
       android:
         generate: true
         adaptive_icon_background: "#121321"  # or background image like assets/icon_bg.png
         adaptive_icon_foreground: "assets/icon_fg.png"
       ios:
         generate: true
       windows:
         generate: true
       macos:
         generate: true
       image_path: "app_icon.png"  # still used for other platforms
     ```
   - Create `assets/icon_fg.png` (transparent foreground) and optionally a solid color or image background.

3. Run the generator
   - From project root:
     ```cmd
     flutter pub get
     flutter pub run flutter_launcher_icons:main
     ```
   - This populates platform-specific icon asset folders:
     - Android: `android/app/src/main/res/mipmap-*` & any adaptive XML files
     - iOS: `ios/Runner/Assets.xcassets/AppIcon.appiconset` (many sizes)
     - Windows: icon in `windows/runner/resources`
     - macOS: `macos/Runner/Assets.xcassets/AppIcon.appiconset`

4. Clean & rebuild (to purge cached old assets)
   ```cmd
   flutter clean
   flutter pub get
   flutter run
   ```

5. Web & Linux manual steps
   - Web: Replace `web/favicon.png` plus optional `web/icons/` images. You can export scaled versions (e.g., 192, 512) for PWA. Update `web/manifest.json` `icons` entries if sizes change.
   - Linux: If you distribute a packaged build, ensure an icon is included; Flutter on Linux can use the generated PNG placed under `linux/` (plugin may not generate automatically). You can copy one of the generated 256x256 PNGs into `linux/assets/icon.png` and reference it in packaging metadata (snap/flatpak spec).

6. Verify
   - Android: Check launcher icon (installed app list) + shape adaptation (circle, squircle) on different devices.
   - iOS: Run on simulator & physical device (light/dark mode) ensuring no unintended background.
   - Windows/macOS: App icon in taskbar/dock and in installer if you build one.
   - Web: Favicon displays; PWA install shows correct icon sizes.

7. Version control
   - Commit the updated generated asset folders. They’re deterministic; if very large you can regenerate, but keeping them avoids requiring the plugin at runtime.

Common pitfalls & tips:
- Blurriness: Start from a crisp vector or high-res bitmap (1024x1024) before scaling.
- Transparent edges clipped: Leave safe margin ~8–10% around artwork.
- Adaptive mismatch: Foreground should NOT include background color; let the mask shape handle it.
- iOS needs no alpha bleeding: avoid semi-transparent outer pixels (could produce halo).

Undo / change later:
- Replace `app_icon.png` (and adaptive foreground/background files) then re-run the generator.

If you want a separate dark-mode variant, that’s not supported directly for launcher icons; create a single design that looks good in both themes.

---
*Clear skies & sharp transits.*
