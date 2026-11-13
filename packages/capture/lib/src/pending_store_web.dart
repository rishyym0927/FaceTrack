import 'dart:js_interop';

@JS('FaceTrackPending.read')
external JSPromise<JSString?> _read();

@JS('FaceTrackPending.save')
external JSPromise<JSAny?> _save(JSString metadata, JSString path);

@JS('FaceTrackPending.clear')
external JSPromise<JSAny?> _clear();

Future<String?> read() async => (await _read().toDart)?.toDart;

Future<void> save(String metadata, String path) async {
  await _save(metadata.toJS, path.toJS).toDart;
}

Future<void> clear() async {
  await _clear().toDart;
}
