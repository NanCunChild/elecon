# Trusted script dependency additions

2026-11-04 ([ADR-084](../adr/adr_084_phone_directory.md)): host-only Flutter official [url_launcher 6.3.3](https://pub.dev/packages/url_launcher/versions/6.3.3) ([upstream](https://github.com/flutter/packages/tree/main/packages/url_launcher)), BSD-3-Clause. Used only to launch a constructed `tel:` URI after a user clicks a validated directory phone number. No direct-call permission or script URI-launch API is added. `pubspec.lock` pins url_launcher and its Android/iOS/Linux/macOS/web/Windows implementations and platform interface; all eight resolved LICENSE files were inspected (BSD-3-Clause). Existing Flutter license aggregation includes their notices. Missing telephone handlers return a fixed failure with a copy-number fallback; actual platform phone-app behavior still requires device validation.

2026-11-04: development-only [Microsoft Playwright](https://github.com/microsoft/playwright), `playwright-core` **1.64.1**, Apache-2.0 (resolved LICENSE inspected). Root `package-lock.json` pins the npm source and integrity. Used only by the [local browser HAR recorder](browser_har_capture.md) to launch an installed Chrome with an isolated profile and export full embedded HTTP HAR; no browser binary download, Flutter/runtime dependency, school-script API or permission change. This package adds no npm transitive dependencies. Raw captures stay outside the repository; real-school data is never a committed test fixture.

2026-11-02 ([ADR-062](../adr/adr_062_app_tunnel_selection.md)): host-only Hermes/aTrust APPTunnel, pinned upstream MIT source at `061de04a699902196475227aece37923e08d646e` (updated 2026-11-04; [alignment record](../research/hermes_upstream_alignment_2026_11_04.md)), is vendored with its LICENSE under `native/hermes_app_tunnel/vendor/hermes`. The local C ABI, exact-address TCP/UDS bridge and certificate fingerprint verifier are documented in [the native README](../../native/hermes_app_tunnel/README.md). Cargo.lock and [the resolved dependency inventory](../../native/hermes_app_tunnel/THIRD_PARTY.json) pin transitive Rust sources; [all retained notices](../../native/hermes_app_tunnel/THIRD_PARTY_NOTICES.txt) and upstream MIT text are packaged as Flutter assets and registered in the license page. No GPL-family alternative is selected; target-only EFI packages are excluded from the Android/Linux normal graph. This is a build-owned dependency, never native code supplied by a school script. The first Android build uses the installed NDK/Rust targets, no system VPN service or TUN permission. `ffi` 2.2.0 (Dart project, BSD-3-Clause, resolved LICENSE inspected) changes from transitive to direct in both platform lockfiles with no version change; native operations run in background Dart isolates. Real gateway/device acceptance and substantive native/network review remain open.

2026-11-02 ([ADR-061](../adr/adr_061_message_history_and_storage.md)): host-only [sqlite3 3.3.4](https://pub.dev/packages/sqlite3/versions/3.3.4) / [upstream](https://github.com/simolus3/sqlite3.dart), MIT; resolved LICENSE inspected. SQLite itself is public domain. The default native asset hook bundles the pinned release's SQLite binary with upstream hash verification; no SQLCipher/GPL dependency is selected. The core uses a memory VFS in background isolates and stores bounded snapshots in the existing H/S/M backend, never a plaintext database/WAL or script-accessible SQL interface. Newly resolved transitive packages `native_toolchain_c` 0.19.2, `file` 7.0.1 and `glob` 2.2.0 are BSD-3-Clause (resolved licenses inspected). Both platform manifests/lockfiles pin sqlite3; existing platform pins are preserved. Flutter includes package licenses in generated NOTICES. This adds no school-script dependency or native-side-loading permission; Android ARM64 Debug packaging was verified, including the SQLite native asset. iOS native packaging and real-device behavior remain separate acceptance work.

ADR-034 file import uses file_picker 13.1.0 (MIT, copyright Miguel Ruivo). License verified from the resolved package LICENSE. It provides the native file chooser, not script execution or credential storage. Existing flutter_qjs_next, flutter_inappwebview, crypto and cryptography are reused. No code was copied from elecon-r.

Resolved new transitive packages (licenses read from each resolved LICENSE):

| Package | License |
|---|---|
| android_file_picker | MIT |
| cross_file | BSD-3-Clause |
| dbus | MPL-2.0 |
| ffi_leak_tracker | BSD-3-Clause |
| file_picker | MIT |
| file_picker_darwin | MIT |
| file_picker_linux | MIT |
| file_picker_platform_interface | MIT |
| file_picker_web | MIT |
| petitparser | MIT |
| win32 | BSD-3-Clause |
| windows_file_picker | MIT |
| xml | MIT |

All additions are resolved through pubspec.lock and pubspec.apple.lock. Both manifests include file_picker so Apple builds expose the same script import surface; existing Apple dependency pins are preserved. Flutter includes resolved package LICENSE files in its generated NOTICES; upstream packages are unmodified. The Linux file chooser brings the MPL-2.0 dbus dependency, recorded explicitly here rather than treating all transitive dependencies as MIT.

2026-10-30: Xidian uses the existing tools esbuild (MIT) and built-in HTML stdlib, without another dependency. The school-specific source is explicitly MPL-2.0, adapted from Traintime PDA; its directory includes the license and provenance, and bundles retain notices. It does not relicense the host.

Real QuickJS testing found pinned flutter_qjs_next 1.2.1 `_jsToDart` omits STRING_ROPE. The trusted SDK linearizes known string fields and its strictly encoded final reply with `String()` before crossing that bridge; invalid non-string values still reach normal validation. The hosted package, native sources and pin are unchanged. The regression includes concatenated credential values, scope, request bodies/headers, browser Cookie/source and output above the rope threshold.

2026-11-01 (ADR-045): mobile_scanner 7.4.3, pinned in both manifests/lockfiles, from [pub.dev](https://pub.dev/packages/mobile_scanner/versions/7.4.3) / [upstream](https://github.com/juliansteenbakker/mobile_scanner), BSD-3-Clause (resolved LICENSE inspected). The foreground QR page uses the device camera and returns decoded text only. Android uses the bundled `com.google.mlkit:barcode-scanning` model (Google ML Kit terms apply to its native binaries); iOS uses AVFoundation/Apple Vision. No gallery or web scan is exposed; Linux/macOS/Windows/OHOS return unavailable. The Dart resolution adds only mobile_scanner; native Android dependency licenses are included by their distributions and require normal release notice review. This does not grant scripts native module access or send frames through elecon's public server.

2026-11-02 ([ADR-058](../adr/adr_058_foreground_device_inputs.md)): SDK 10 uses Flutter's [image_picker 1.2.4](https://pub.dev/packages/image_picker/versions/1.2.4) ([upstream](https://github.com/flutter/packages/tree/main/packages/image_picker), BSD-3-Clause with bundled Apache-2.0 notices) for explicitly requested camera/gallery input, and Baseflow's [geolocator 14.0.2](https://pub.dev/packages/geolocator/versions/14.0.2) ([upstream](https://github.com/Baseflow/flutter-geolocator), MIT) for one foreground position fix. Versions are pinned in both manifests and lockfiles. Native input is enabled only on Android/iOS; no background location, microphone, arbitrary files or native module access is granted. Images are bounded and re-encoded by existing Flutter image codecs; no image-processing dependency was added.

The resolved LICENSE files were inspected for every newly resolved package:

| Package | License |
|---|---|
| image_picker, image_picker_android, image_picker_ios | BSD-3-Clause, bundled Apache-2.0 notices |
| image_picker_for_web, image_picker_linux, image_picker_macos, image_picker_platform_interface, image_picker_windows | BSD-3-Clause |
| file_selector_linux, file_selector_macos, file_selector_platform_interface, file_selector_windows | BSD-3-Clause |
| geolocator, geolocator_android, geolocator_apple, geolocator_linux, geolocator_platform_interface, geolocator_web, geolocator_windows | MIT |
| geoclue 0.1.1, gsettings 0.2.8 | MPL-2.0 |
| fixnum, flutter_plugin_android_lifecycle, http, http_parser, mime, package_info_plus, package_info_plus_platform_interface | BSD-3-Clause |
| uuid | MIT |

Linux resolution also reuses the existing MPL-2.0 dbus package. These upstream sources are unmodified, retain their licenses and source links, and are covered by Flutter's generated NOTICES. The MPL packages are file-level copyleft dependencies, not GPL components; SDK 10 does not enable Linux input or relicense the host. Apple resolution preserves its platform pins; its dbus/file_picker_linux versions follow the geolocator constraints. The selected dependencies raise the resolved minimum to Flutter 3.44 / Dart 3.12. Android/iOS permission configuration follows the packages' official setup instructions; Apple builds set `BYPASS_PERMISSION_LOCATION_ALWAYS=1` through the existing Apple build wrapper.
