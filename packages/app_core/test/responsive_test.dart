import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:facetrack_core/facetrack_core.dart';

void main() {
  for (final width in [360.0, 390.0, 768.0, 1440.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('Workspace fits $width with text scale $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var tapped = false;
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: Scaffold(
              body: ContentPage(
                children: [
                  PageHeader(
                    title:
                        'Advanced Data Structures and Algorithms — Section A',
                    subtitle: 'Review membership and published attendance for your class.',
                    action: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: () {},
                          child: const Text('Refresh'),
                        ),
                        FilledButton(
                          onPressed: () => tapped = true,
                          child: const Text('Join code'),
                        ),
                      ],
                    ),
                  ),
                  const MessageView(
                    title: 'No requests yet',
                    message: 'New requests will appear here.',
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Join code'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Join code'));
        expect(tapped, isTrue);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
