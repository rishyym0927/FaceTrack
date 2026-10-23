import 'dart:io';

import 'package:path_provider/path_provider.dart';

Future<void> remove(String path) async {
  final base = await getApplicationSupportDirectory();
  final cache = await getTemporaryDirectory();
  if (!path.startsWith('${base.path}/') && !path.startsWith('${cache.path}/'))
    return;
  final file = File(path);
  if (await file.exists()) await file.delete();
}

Future<String> retain(String path, String identifier) async {
  if (!RegExp(r'^[a-fA-F0-9-]{36}$').hasMatch(identifier))
    throw const FormatException('Invalid capture ID');
  final directory = Directory(
    '${(await getApplicationSupportDirectory()).path}/face-enrolment',
  );
  await directory.create(recursive: true);
  final target = '${directory.path}/$identifier.video';
  if (path == target) return path;
  await File(path).copy(target);
  await remove(path);
  return target;
}
