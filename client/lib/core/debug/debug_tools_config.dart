import 'package:flutter/foundation.dart';

/// ADR-100: never enabled in profile/release, even with the define present.
const debugToolsEnabled =
    kDebugMode && bool.fromEnvironment('ELECON_DEBUG_TOOLS');
