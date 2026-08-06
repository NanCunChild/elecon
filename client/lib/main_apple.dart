import 'main.dart' as app;
import 'ui/theme/liquid_glass_apple.dart';

Future<void> main() async {
  await app.runEleconApp(
    initializePlatformUi: initializeAppleLiquidGlass,
    wrapApp: wrapAppleLiquidGlass,
  );
}
