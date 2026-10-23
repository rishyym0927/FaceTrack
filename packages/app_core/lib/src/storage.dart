import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class NativeSessionStorage extends LocalStorage {
  NativeSessionStorage(this.key);
  final String key;
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> hasAccessToken() async => (await accessToken()) != null;
  @override
  Future<String?> accessToken() => _storage.read(key: key);
  @override
  Future<void> persistSession(String persistSessionString) =>
      _storage.write(key: key, value: persistSessionString);
  @override
  Future<void> removePersistedSession() => _storage.delete(key: key);
}
