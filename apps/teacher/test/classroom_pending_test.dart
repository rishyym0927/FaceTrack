import 'dart:io';
import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:facetrack_teacher/classroom_pending.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('pending classroom clip and upload checkpoint survive a new store', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp('classroom-recovery-');
    addTearDown(() => directory.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => directory.path,
        );
    final original = await File('${directory.path}/clip.mp4').writeAsString('clip');
    final store = ClassroomPending('teacher', 'institute', 'session');
    final saved = await store.retain(XFile(original.path), {
      'reserve_key': 'reserve',
      'capture': null,
    });
    expect(await File(saved.path).exists(), isTrue);
    final preferences = await SharedPreferences.getInstance();
    final key = preferences.getKeys().single;
    final created = (jsonDecode(preferences.getString(key)!) as Map)['created'];
    await store.update(saved.path, {
      'reserve_key': 'reserve',
      'capture': {'id': 'capture'},
      'resume_url': 'private-checkpoint',
    });
    expect((jsonDecode(preferences.getString(key)!) as Map)['created'], created);
    final reopened = ClassroomPending('teacher', 'institute', 'session');
    final entries = await reopened.load();
    expect(entries, hasLength(1));
    expect((entries.single['upload'] as Map)['resume_url'], 'private-checkpoint');
    expect(await ClassroomPending('other', 'institute', 'session').load(), isEmpty);
    // Opening another account or session cannot delete this teacher's clip.
    expect(await ClassroomPending('teacher', 'institute', 'other-session').load(), isEmpty);
    expect(await File(saved.path).exists(), isTrue);
    await reopened.remove(saved.path);
    expect(await File(saved.path).exists(), isFalse);
    final again = await store.retain(XFile(original.path), {'reserve_key': 'next'});
    final stored = jsonDecode(preferences.getString(key)!) as Map<String, dynamic>;
    stored['created'] = DateTime.now()
        .subtract(const Duration(hours: 25))
        .toUtc()
        .toIso8601String();
    await preferences.setString(key, jsonEncode(stored));
    expect(await store.load(), isEmpty);
    expect(await File(again.path).exists(), isFalse);
    final logout = await store.retain(XFile(original.path), {'reserve_key': 'logout'});
    await ClassroomPending.clearAll();
    expect(await File(logout.path).exists(), isFalse);
    expect(await store.load(), isEmpty);
  });
}
