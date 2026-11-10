import 'files_stub.dart'
    if (dart.library.io) 'files_io.dart'
    if (dart.library.js_interop) 'files_web.dart'
    as files;

/// Release only private app-owned camera files or browser blob URLs.
Future<void> removeOwnedClip(String path) => files.remove(path);
