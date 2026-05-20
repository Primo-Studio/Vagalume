# BrightBar Handoff Notes

Last updated: 2026-05-20

## BrightBar State

- Repository: `/Users/primostudio/BrightBar`
- Branch: `main`
- Latest pushed BrightBar commit at last check:
  `574f6db Improve F1 F2 brightness key handling`
- App launch command:
  `./script/build_and_run.sh --verify`
- Verified commands after the latest code changes:
  - `swift build`
  - `swift test`
  - `./script/build_and_run.sh --verify`

## Implemented Recently

- Added a BrightBar power toggle that disables the app without quitting it.
- When BrightBar is disabled:
  - F1/F2 handling is released.
  - Option + arrow fallback hotkeys are unregistered.
  - keyboard event taps and fallback monitors are stopped.
  - pending keyboard brightness changes are cancelled.
  - software dimming windows are closed.
- Stabilized dimming overlays:
  - overlay windows ignore mouse events.
  - overlay level is `.statusBar`, not `.screenSaver`.
  - disabling BrightBar fully closes overlays.
- Fixed stale display slider state:
  - per-display sliders now read current manager state by display ID.
- Added nits estimates and editable max-nits values per display.
- Added F1/F2 fallback handling through Carbon hotkeys, in addition to macOS
  system-defined brightness events.
- Local app bundles are now signed with
  `Developer ID Application: Primo Studio (4QB44XVHNL)` when that identity is
  available, instead of only ad-hoc signing. This should make macOS
  Accessibility permissions more stable between local builds.
- Accessibility permission prompts were throttled:
  - refreshes check silently.
  - the UI exposes a manual keyboard permission button if needed.

## Lunar Removal

Lunar was uninstalled by moving files to the Trash, not deleting permanently.

Moved to `~/.Trash`:

- `/Applications/Lunar.app`
- `~/Library/Application Support/Lunar`
- `~/Library/Caches/SentryCrash/Lunar`
- `~/Library/Caches/fyi.lunar.Lunar`
- `~/Library/HTTPStorages/fyi.lunar.Lunar`
- `~/Library/Preferences/fyi.lunar.Lunar.plist`
- `~/Library/WebKit/fyi.lunar.Lunar`
- `~/Library/Application Support/CrashReporter/Lunar_75A198CC-1D9E-52A2-9953-590BFEB7AE35.plist`

Left untouched:

- ClickUp icon cache entries referencing Lunar, because those belong to ClickUp.

Post-checks at the time:

- no `Lunar.app` in `/Applications`
- no Lunar process
- no Lunar LaunchAgent found

## Bluetooth Keyboard F11/F12 Investigation

User device context:

- MacBook Pro 2021, French layout.
- Built-in keyboard works correctly.
- External Bluetooth keyboard is an Apple Magic Keyboard, product ID `0x029C`.
- Two Magic Keyboard devices appeared in Bluetooth information:
  - `Magic Keyboard de Neto`
  - `Magic Keyboard`

User symptom:

- On the Bluetooth Magic Keyboard, F11/F12 no longer behave as volume
  down/up. User asked to verify before changing anything further.

What was checked:

- `defaults read -g com.apple.keyboard.fnState`
  - unset
- `defaults -currentHost read -g com.apple.keyboard.fnState`
  - unset
- `hidutil property --get '{"UserKeyMapping":[]}'`
  - `(null)`, so no HID user key remap was active.
- BrightBar source search:
  - no F11/F12 capture.
  - BrightBar handles F1/F2 brightness and Option + arrow fallback only.
- `system_profiler SPBluetoothDataType`
  - Magic Keyboard detected over Bluetooth.
- `ioreg` for `AppleHIDKeyboardEventDriverV2`
  - external Apple keyboard service showed `HIDFKeyMode = 0`.
  - this means macOS should treat the top row as special/media keys, not plain
    function keys.
- `com.apple.symbolichotkeys.plist`
  - F11/F12-related shortcuts were found enabled earlier:
    - IDs `36` and `37`, keycode `103`
    - IDs `62` and `63`, keycode `111`

What was changed before the user asked to stop changing:

- A backup was created:
  `~/Library/Preferences/com.apple.symbolichotkeys.plist.brightbar-backup-20260513-144341`
- The following symbolic hotkeys were disabled:
  - `36`
  - `37`
  - `62`
  - `63`
- `cfprefsd`, `Dock`, and `SystemUIServer` were restarted.

After that change:

- F11/F12 still did not work as expected for the user.
- Current plist check showed those symbolic hotkeys disabled.

Remaining suspects:

- Logi Options+ is running and installs global input agents:
  - `logioptionsplus_agent`
  - `logioptionsplus_updater`
- Even though the keyboard is Apple, Logi Options+ can still participate in
  global input handling because the user has Logitech devices.
- A raw NSEvent monitor launched from Codex did not receive F11/F12 events,
  likely because the temporary Swift process did not have the right global
  input permissions or because the key presses were not captured during the
  listening window.

Do not assume BrightBar caused F11/F12:

- BrightBar code does not handle `kVK_F11`, `kVK_F12`, volume up, volume down,
  or mute.
- Current evidence points away from BrightBar and toward macOS keyboard state,
  Bluetooth keyboard state, or a global input agent.

## Recommended Next Steps

1. Re-test F11/F12 with BrightBar disabled from its power button.
2. Temporarily quit Logi Options+ and retest F11/F12.
3. Test F11/F12 while holding `Fn/Globe`.
4. Open System Settings > Keyboard > Keyboard Shortcuts and inspect:
   - Mission Control
   - Keyboard
   - Function Keys
   - App Shortcuts
5. If needed, restore the symbolic hotkeys backup:
   `~/Library/Preferences/com.apple.symbolichotkeys.plist.brightbar-backup-20260513-144341`
6. If event-level proof is needed, use a signed/local helper with Accessibility
   permission to print NSEvent or CGEvent data while pressing F11/F12.

