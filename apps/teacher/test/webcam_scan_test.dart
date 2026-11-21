import 'package:facetrack_capture/facetrack_capture.dart';
import 'package:facetrack_teacher/classroom_scan.dart';
import 'package:facetrack_teacher/recognition_board.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

CameraDescription cam(String name, [CameraLensDirection lens = CameraLensDirection.external]) =>
    CameraDescription(name: name, lensDirection: lens, sensorOrientation: 0);

final builtIn = cam('FaceTime HD Camera (Built-in)', CameraLensDirection.front);
final usb = cam('Logitech BRIO (046d:085e)');
final usb2 = cam('Razer Kiyo (1532:0e05)');

class WebcamFake extends GuidedCamera {
  WebcamFake(List<CameraDescription> all) {
    cameras = all;
    selectedCamera = all.first;
  }
  final selections = <String>[];
  bool failOpen = false;
  @override
  Future<void> initialize() async => ready = !failOpen;
  @override
  Future<void> start(List<String> order) async {
    recording = true;
    emit();
  }

  @override
  Future<void> stop({int minimumSeconds = 10}) async {
    recording = false;
    emit();
  }

  @override
  Future<void> refreshCameras() async {}
  @override
  Future<void> selectCamera(CameraDescription choice) async {
    selections.add(choice.name);
    selectedCamera = choice;
    ready = !failOpen;
    lost = false;
    emit();
  }

  /// What the real camera does when the device is unplugged.
  void unplug(List<CameraDescription> remaining) {
    lostCamera = selectedCamera;
    lost = true;
    ready = false;
    recording = false;
    cameras = remaining;
    emit();
  }

  @override
  Future<void> interrupt({bool lifecycle = false}) async {
    recording = false;
    ready = false;
  }
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  group('choosing a webcam', () {
    test('a USB webcam is preferred over the laptop camera for a classroom scan', () {
      expect(preferredCamera([builtIn, usb], enrollment: false), usb);
      expect(preferredCamera([builtIn, usb], enrollment: true), builtIn);
      expect(preferredCamera([builtIn], enrollment: false), builtIn);
    });

    test('the camera used last is reused when it is still plugged in', () {
      expect(preferredCamera([usb, usb2], enrollment: false, remembered: usb2.name), usb2);
      expect(preferredCamera([usb], enrollment: false, remembered: 'unplugged'), usb);
    });

    test('a phone flips between front and rear, webcams step through the list', () {
      final phone = WebcamFake([cam('0', CameraLensDirection.back), cam('1', CameraLensDirection.front)]);
      expect(phone.hasFrontRear, isTrue);
      expect(phone.otherCamera, phone.cameras[1]);
      final desk = WebcamFake([builtIn, usb, usb2]);
      expect(desk.hasFrontRear, isFalse);
      expect(desk.otherCamera, usb);
      desk.selectedCamera = usb2;
      expect(desk.otherCamera, builtIn); // wraps round
      expect(WebcamFake([usb]).canSwitch, isFalse);
    });

    test('names are readable, without the USB id the browser appends', () {
      final phone = [cam('0', CameraLensDirection.back), cam('2', CameraLensDirection.back), cam('1', CameraLensDirection.front)];
      expect(describeCamera(phone[0], phone), 'Rear camera 1');
      expect(describeCamera(phone[2], phone), 'Front camera');
      expect(describeCamera(cam('x', CameraLensDirection.external), [cam('x')]), 'External camera');
    });
  });

  group('light and framing advice', () {
    test('too dark and too bright are told apart from a normal room', () {
      expect(lightingOf(null), Lighting.unknown);
      expect(lightingOf(30), Lighting.tooDark);
      expect(lightingOf(120), Lighting.good);
      expect(lightingOf(230), Lighting.tooBright);
    });

    test('faces judged by the browser keep their framing state', () {
      final tracker = LiveFaceTracker();
      tracker.observeBoxes([
        (id: 1, bounds: const Rect.fromLTWH(.1, .1, .1, .2), framed: true),
        (id: 2, bounds: const Rect.fromLTWH(.5, .1, .05, .1), framed: false),
      ], DateTime.now());
      expect(tracker.faces.map((f) => f.framed), [true, false]);
      expect(tracker.available, isTrue);
    });

    test('a browser reading becomes faces and a light level', () {
      final reading = FramingReading.fromJson({
        'video': true,
        'detector': true,
        'light': 88,
        'width': 1280,
        'height': 720,
        'faces': [
          {'id': 3, 'x': .2, 'y': .3, 'w': .1, 'h': .15, 'framed': true},
        ],
      });
      expect(reading.faces!.single.id, 3);
      expect(reading.faces!.single.bounds.width, closeTo(.1, 1e-9));
      expect(FramingReading.fromJson({'video': true, 'faces': null}).faces, isNull);
    });
  });

  group('scan page with several webcams', () {
    Future<(ClassroomScan, WebcamFake)> open(WidgetTester tester, List<CameraDescription> all) async {
      final camera = WebcamFake(all);
      final scan = ClassroomScan(camera, (file) async {});
      addTearDown(scan.dispose);
      await tester.pumpWidget(
        MaterialApp(home: ClassroomScanPage(scan: scan, results: () async => const RecognitionSnapshot([]))),
      );
      await settle(tester);
      return (scan, camera);
    }

    testWidgets('the camera menu lists every camera and switches to the one picked', (tester) async {
      final (scan, camera) = await open(tester, [builtIn, usb, usb2]);
      await scan.start();
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('camera-menu')));
      await settle(tester);
      expect(find.text('External camera 1'), findsOneWidget);
      expect(find.text('External camera 2'), findsOneWidget);
      await tester.tap(find.text('External camera 2'));
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(camera.selections, ['Razer Kiyo (1532:0e05)']);
      expect(scan.scanning, isTrue); // recording carries on after the switch
      expect(camera.recording, isTrue);
    });

    testWidgets('no camera menu for a single webcam, and no flip button either', (tester) async {
      await open(tester, [usb]);
      expect(find.byKey(const ValueKey('camera-menu')), findsNothing);
      expect(find.byKey(const ValueKey('flip-camera')), findsNothing);
    });

    testWidgets('a dark room is called out before recording', (tester) async {
      final (_, camera) = await open(tester, [usb]);
      camera
        ..ready = true
        ..lighting = Lighting.tooDark
        ..emit();
      await settle(tester);
      expect(find.textContaining('Too dark'), findsOneWidget);
      camera
        ..lighting = Lighting.tooBright
        ..emit();
      await settle(tester);
      expect(find.textContaining('Too bright'), findsOneWidget);
    });
  });

  group('an unplugged webcam', () {
    test('the scan moves to another camera and keeps recording', () async {
      final camera = WebcamFake([usb, usb2]);
      final events = <String>[];
      final scan = ClassroomScan(camera, (file) async {}, onEvent: (name, {code, attempt, bytes, count, durationMs}) => events.add(name));
      addTearDown(scan.dispose);
      await scan.start();
      expect(camera.recording, isTrue);
      camera.unplug([usb2]);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(camera.selections, [usb2.name]);
      expect(scan.scanning, isTrue);
      expect(camera.recording, isTrue);
      expect(scan.cameraError, contains('Continuing on'));
      expect(events, contains('camera_recovered'));
    });

    test('with no other camera the scan pauses and asks to reconnect', () async {
      final camera = WebcamFake([usb]);
      final scan = ClassroomScan(camera, (file) async {});
      addTearDown(scan.dispose);
      await scan.start();
      camera.unplug([]);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(scan.scanning, isFalse);
      expect(scan.cameraError, contains('Reconnect'));
      expect(camera.recording, isFalse);
      // Plugging it back in and pressing Start resumes.
      camera.cameras = [usb];
      await scan.start();
      expect(camera.recording, isTrue);
    });
  });
}
