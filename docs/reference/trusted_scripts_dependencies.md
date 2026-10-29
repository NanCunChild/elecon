# Trusted script dependency additions

ADR-034 file import uses file_picker 13.1.0 (MIT, copyright Miguel Ruivo). License verified from the resolved package LICENSE. It provides the native file chooser, not script execution or credential storage. Existing flutter_qjs_next, flutter_inappwebview, crypto and cryptography are reused. No code was copied from elecon-r.

Resolved new transitive packages (licenses read from each resolved LICENSE):

| Package | License |
|---|---|
| android_file_picker | MIT |
| cross_file | BSD-3-Clause |
| dbus | Mozilla Public License Version 2.0 |
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
