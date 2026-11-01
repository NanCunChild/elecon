# Trusted script dependency additions

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
