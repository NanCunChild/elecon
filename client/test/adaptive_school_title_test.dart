import 'package:elecon/ui/widgets/adaptive_school_title.dart';
import 'package:elecon/ui/home/home_page.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const longName = 'A very long synthetic university name';

Widget app({
  String text = longName,
  double width = 120,
  double scale = 1,
  bool reduced = false,
  bool ticking = true,
  TextDirection direction = TextDirection.ltr,
}) => MaterialApp(
  home: Scaffold(
    body: MediaQuery(
      data: MediaQueryData(
        textScaler: TextScaler.linear(scale),
        disableAnimations: reduced,
      ),
      child: Directionality(
        textDirection: direction,
        child: TickerMode(
          enabled: ticking,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: AdaptiveSchoolTitle(
                text: text,
                style: const TextStyle(fontSize: 32),
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

ScrollController controller(WidgetTester tester) => tester
    .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
    .controller!;

Future<void> moving(WidgetTester tester) async {
  for (var i = 0; i < 25 && controller(tester).offset == 0; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
  expect(controller(tester).offset, greaterThan(0));
}

void main() {
  testWidgets(
    'home keeps a separate type subtitle on narrow RTL large-text layouts',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('fa'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: EleconHomePage(
            loadSnapshot: () async => const CampusSnapshot(
              schoolName: longName,
              schoolType: 'Synthetic postgraduate type',
              updatedAt: null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final title = tester.widget<AdaptiveSchoolTitle>(
        find.byKey(const ValueKey('home-title')),
      );
      expect(title.text, longName);
      expect(find.byKey(const ValueKey('home-school-type')), findsOneWidget);
      expect(find.text('Synthetic postgraduate type'), findsOneWidget);
      expect(
        Directionality.of(tester.element(find.byType(AdaptiveSchoolTitle))),
        TextDirection.rtl,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('one-line title shrinks only as far as needed before scrolling', (
    tester,
  ) async {
    await tester.pumpWidget(app(text: 'Campus', width: 220));
    expect(tester.widget<Text>(find.text('Campus')).style!.fontSize, 32);
    expect(controller(tester).position.maxScrollExtent, 0);
    await tester.pumpWidget(app(text: 'Synthetic university', width: 440));
    final title = tester.widget<Text>(find.text('Synthetic university'));
    expect(title.style!.fontSize, allOf(greaterThan(18), lessThan(32)));
    expect(title.maxLines, 1);
    expect(controller(tester).position.maxScrollExtent, closeTo(0, .1));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'overflow reaches minimum, scrolls, and announces full text once',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(app());
      expect(tester.widget<Text>(find.text(longName)).style!.fontSize, 18);
      expect(find.bySemanticsLabel(longName), findsOneWidget);
      await moving(tester);
      await tester.pumpWidget(app(text: 'Campus', width: 220));
      await tester.pumpAndSettle();
      expect(controller(tester).offset, 0);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets(
    'RTL starts at the reading edge and scrolls within the viewport',
    (tester) async {
      await tester.pumpWidget(app(direction: TextDirection.rtl));
      expect(controller(tester).position.axisDirection, AxisDirection.left);
      expect(controller(tester).offset, 0);
      await moving(tester);
      expect(
        controller(tester).offset,
        lessThanOrEqualTo(controller(tester).position.maxScrollExtent),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'large text and reduced motion keep readable minimum and manual scroll',
    (tester) async {
      await tester.pumpWidget(app(scale: 2, reduced: true));
      final title = tester.widget<Text>(find.text(longName));
      expect(title.style!.fontSize, 18);
      expect(
        MediaQuery.textScalerOf(tester.element(find.text(longName))).scale(18),
        36,
      );
      await tester.pump(const Duration(seconds: 30));
      expect(controller(tester).offset, 0);
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(-80, 0),
      );
      await tester.pumpAndSettle();
      expect(controller(tester).offset, greaterThan(0));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'covered route pauses scrolling until the school page is visible again',
    (tester) async {
      await tester.pumpWidget(app());
      await moving(tester);
      final scroll = controller(tester);
      final navigator = Navigator.of(
        tester.element(find.byType(AdaptiveSchoolTitle)),
      );
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Other page')),
        ),
      );
      await tester.pumpAndSettle();
      final hidden = scroll.offset;
      await tester.pump(const Duration(seconds: 10));
      expect(scroll.offset, hidden);
      navigator.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      var resumed = false;
      for (var i = 0; i < 25 && !resumed; i++) {
        await tester.pump(const Duration(seconds: 1));
        resumed = scroll.offset != hidden;
      }
      expect(resumed, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ticker and app lifecycle suspend movement and disposal releases it',
    (tester) async {
      await tester.pumpWidget(app());
      await moving(tester);
      await tester.pumpWidget(app(ticking: false));
      final paused = controller(tester).offset;
      await tester.pump(const Duration(seconds: 10));
      expect(controller(tester).offset, paused);
      await tester.pumpWidget(app());
      await tester.pump(const Duration(milliseconds: 100));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final background = controller(tester).offset;
      await tester.pump(const Duration(seconds: 10));
      expect(controller(tester).offset, background);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
      expect(tester.takeException(), isNull);
    },
  );
}
