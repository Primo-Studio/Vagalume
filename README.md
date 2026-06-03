# Vagalume

Vagalume is a lightweight macOS menu bar app for display brightness control.
It focuses on the useful part of Lunar: fast brightness control without
profiles, schedules, cloud accounts, or subscriptions.

## Download

Download the latest notarized build from GitHub Releases:

https://github.com/Primo-Studio/Vagalume/releases/latest

Unzip `Vagalume-*-macOS.zip`, move `Vagalume.app` to `/Applications`, then
launch it. macOS may ask for Accessibility permission so Vagalume can intercept
the brightness keys.

## Features

- Menu bar only, no Dock icon.
- Global brightness slider for all controllable displays.
- Per-display sliders.
- Built-in display control through macOS.
- External display DDC/CI probing on Apple Silicon.
- Software dimming fallback when DDC is unavailable.
- Sub-zero dimming below 20%.
- Presets: 5%, 20%, 50%, 100%.
- Native brightness keys support, standard `F1`/`F2` fallback, plus
  `Option + Up` and `Option + Down`.
- Enable/disable toggle that releases keyboard hooks and closes software dimming.
- Estimated nits per display, based on configurable max-nits values.
- Sparkle-based automatic updates through GitHub Releases.

## Limitations

External display hardware brightness depends on DDC/CI support. Some monitors,
inputs, USB-C docks, and adapters block DDC commands. When Vagalume shows
`Logiciel`, it can dim visually with an overlay but cannot raise the monitor's
real hardware brightness.

Nit values are estimates. macOS and DDC/CI expose brightness levels, not
calibrated luminance readings.

When Vagalume is disabled from the power button, it stops handling F1/F2,
unregisters its fallback shortcuts, and removes software dimming overlays.

Local builds are signed with the Primo Studio Developer ID when available so
macOS Accessibility permissions stay attached to the same app identity between
builds.

## Build

```sh
swift build
```

## Test

```sh
swift test
```

## Run Locally

```sh
./script/build_and_run.sh
```

## Package

Local app bundle:

```sh
./Scripts/package_app.sh
```

Signed release ZIP:

```sh
./Scripts/package_release.sh
```

Notarized release ZIP:

```sh
NOTARY_PROFILE=Vagalume-Notary ./Scripts/package_release.sh --notarize
```

Generate the Sparkle appcast after creating the notarized ZIP:

```sh
./Scripts/generate_appcast.sh
```

## Updates

Vagalume checks the `appcast.xml` asset from the latest GitHub Release at most
once per day. The footer button can manually trigger "Check for Updates".

## Privacy

Vagalume does not collect analytics, telemetry, crash reports, personal data,
or display usage data. See [PRIVACY.md](PRIVACY.md).

## License

MIT. See [LICENSE](LICENSE).
