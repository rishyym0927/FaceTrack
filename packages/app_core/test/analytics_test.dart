import 'package:facetrack_core/facetrack_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(
  WidgetTester t,
  Widget child, {
  Size size = const Size(360, 800),
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  await t.pumpWidget(
    MaterialApp(
      theme: appTheme(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('StatTile renders its label and animated value', (t) async {
    await _pump(
      t,
      const StatTile(label: 'Below 75%', value: 7, icon: Icons.trending_down),
    );
    expect(find.text('Below 75%'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('PercentRing shows a rounded percentage', (t) async {
    await _pump(t, const PercentRing(value: 82.4));
    expect(find.text('82%'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('PercentRing shows an em dash when there is no value', (t) async {
    await _pump(t, const PercentRing(value: null));
    expect(find.text('—'), findsOneWidget);
  });

  testWidgets('StatGrid lays four tiles out at phone width without overflow',
      (t) async {
    await _pump(
      t,
      const StatGrid(
        children: [
          StatTile(label: 'A', value: 1),
          StatTile(label: 'B', value: 2),
          StatTile(label: 'C', value: 3),
          StatTile(label: 'D', value: 4),
        ],
      ),
    );
    expect(find.byType(StatTile), findsNWidgets(4));
    expect(t.takeException(), isNull);
  });

  testWidgets('percentColor crosses thresholds', (t) async {
    expect(percentColor(90), const Color(0xff176451));
    expect(percentColor(60), const Color(0xff9a6a00));
    expect(percentColor(40), const Color(0xffa22f2f));
    expect(percentColor(null), const Color(0xff587067));
  });
}
