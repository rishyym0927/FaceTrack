import 'package:facetrack_core/facetrack_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  Future<void> show(
    WidgetTester tester,
    Size size, {
    AppRole role = AppRole.teacher,
    double keyboard = 0,
    double scale = 1,
  }) async {
    final h = (await tester.runAsync(() => harness(role: role, signedIn: false)))!;
    addTearDown(() => tester.runAsync(h.dispose));
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(h.services)],
        child: MaterialApp(
          theme: appTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const LoginPage(),
        ),
      ),
    );
    await tester.pump();
  }

  group('phones', () {
    for (final size in const [Size(320, 568), Size(360, 640), Size(390, 844), Size(412, 915)]) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()}: branded, no overflow', (tester) async {
        await show(tester, size);
        expect(tester.takeException(), isNull);
        expect(find.text('FaceTrack'), findsWidgets);
        expect(find.bySemanticsLabel('FaceTrack'), findsWidgets); // the logo mark
        expect(find.text('Faculty portal'), findsOneWidget);
        expect(find.text('Welcome back'), findsOneWidget);
        expect(find.text('Email address'), findsOneWidget);
      });
    }
    testWidgets('the sign-in button is on screen without scrolling from 360x640 up', (tester) async {
      for (final size in const [Size(360, 640), Size(390, 844), Size(412, 915)]) {
        await show(tester, size);
        final button = tester.getRect(find.widgetWithText(FilledButton, 'Sign in'));
        expect(button.bottom, lessThanOrEqualTo(size.height), reason: '$size');
        expect(button.top, greaterThan(0));
        await tester.pumpWidget(const SizedBox());
      }
    });
    testWidgets('with the keyboard open the header shrinks and the form stays reachable', (tester) async {
      await show(tester, const Size(360, 640), keyboard: 300);
      expect(tester.takeException(), isNull);
      expect(find.text('Attendance in minutes.'), findsNothing); // compact header
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pump();
      final button = tester.getRect(find.widgetWithText(FilledButton, 'Sign in'));
      expect(button.bottom, lessThanOrEqualTo(640 - 300 + 80));
    });
    testWidgets('the student portal has its own wording', (tester) async {
      await show(tester, const Size(390, 844), role: AppRole.student);
      expect(find.text('Student portal'), findsOneWidget);
      expect(find.text('Your attendance, made clear.'), findsOneWidget);
      expect(find.text('Faculty portal'), findsNothing);
    });
    testWidgets('large text still fits and scrolls', (tester) async {
      await show(tester, const Size(360, 640), scale: 2);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Sign in'));
      expect(tester.takeException(), isNull);
    });
  });

  group('wide screens', () {
    testWidgets('a split layout shows the brand beside the form', (tester) async {
      await show(tester, const Size(1280, 800));
      expect(tester.takeException(), isNull);
      expect(find.text('Attendance in minutes.'), findsOneWidget);
      expect(find.textContaining('Review every suggestion'), findsOneWidget);
      final form = tester.getRect(find.text('Welcome back'));
      final brand = tester.getRect(find.text('Attendance in minutes.'));
      expect(form.left, greaterThan(brand.right)); // side by side, not stacked
    });
    testWidgets('a tablet is wide enough for the split layout', (tester) async {
      await show(tester, const Size(900, 1000));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Review every suggestion'), findsOneWidget);
    });
  });

  testWidgets('the form still works: validation shows inline errors', (tester) async {
    await show(tester, const Size(390, 844));
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();
    expect(find.text('Enter a valid email address.'), findsOneWidget);
    expect(find.text('This field is required.'), findsOneWidget);
  });
}
