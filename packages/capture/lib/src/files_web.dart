import 'package:web/web.dart' as web;

Future<void> remove(String path) async {
  if (path.startsWith('blob:')) web.URL.revokeObjectURL(path);
}

Future<String> retain(String path, String identifier) async => path;
