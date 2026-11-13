import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

Future<Directory> _directory() async {
  final base = await getApplicationSupportDirectory();
  final directory = Directory('${base.path}/classroom-pending');
  await directory.create(recursive: true);
  return directory;
}

Future<bool> exists(String path) async {
  final directory = await _directory();
  return path.startsWith('${directory.path}/') && File(path).existsSync();
}

Future<String> retain(String path) async {
  final directory = await _directory();
  final target = '${directory.path}/${const Uuid().v4()}.video';
  await File(path).copy(target);
  return target;
}

Future<void> remove(String path) async {
  final directory = await _directory();
  if (!path.startsWith('${directory.path}/')) return;
  final file = File(path);
  if (await file.exists()) await file.delete();
}
