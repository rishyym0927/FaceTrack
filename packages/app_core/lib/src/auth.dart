import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:facetrack_models/facetrack_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'api.dart';
import 'config.dart';
import 'storage.dart';

class AppServices {
  AppServices(this.config, this.client, this.storage)
    : api = ApiClient(client, config.apiUrl);
  final AppConfig config;
  final SupabaseClient client;
  final LocalStorage storage;
  Future<void> Function()? clearPrivateMedia;
  final ApiClient api;
  static Future<AppServices> initialize(AppConfig config) async {
    config.validate();
    final LocalStorage storage = kIsWeb
        ? SharedPreferencesLocalStorage(persistSessionKey: config.storageKey)
        : NativeSessionStorage(config.storageKey);
    await Supabase.initialize(
      url: config.supabaseUrl,
      publishableKey: config.publishableKey,
      authOptions: FlutterAuthClientOptions(localStorage: storage),
      debug: false,
    );
    return AppServices(config, Supabase.instance.client, storage);
  }
}

final servicesProvider = Provider<AppServices>(
  (ref) => throw StateError('Application services not configured.'),
);
final authProvider = ChangeNotifierProvider<AuthController>(
  (ref) => AuthController(ref.read(servicesProvider)),
);

class AuthController extends ChangeNotifier {
  AuthController(this.services) {
    services.api.onSessionLost = () => unawaited(signOut());
    _subscription = services.client.auth.onAuthStateChange.listen(
      (event) {
        final next = event.session?.user.id;
        if (_user != next) {
          services.api.clear();
          _user = next;
          account = null;
          institute = null;
        }
        unawaited(load());
      },
      onError: (_) {
        error = const AppFailure(
          'Could not restore your session. Please retry.',
        );
        _notify();
      },
    );
    scheduleMicrotask(load);
  }
  final AppServices services;
  StreamSubscription<AuthState>? _subscription;
  Account? account;
  String? institute, _user;
  AppFailure? error;
  bool loading = true, _disposed = false;
  int _generation = 0;
  bool get signedIn => services.client.auth.currentSession != null;
  List<Member> get memberships =>
      account?.eligible(services.config.roleName) ?? [];
  bool get canClaim =>
      services.config.role == AppRole.student && (account?.canClaim ?? false);
  Person? get person {
    final records = services.config.role == AppRole.student
        ? account?.students
        : account?.teachers;
    for (final record in records ?? <Person>[]) {
      if (record.instituteId == institute) return record;
    }
    return null;
  }

  String get instituteName {
    for (final m in memberships) {
      if (m.instituteId == institute) return m.instituteName;
    }
    return '';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    final generation = ++_generation;
    error = null;
    if (!signedIn) {
      account = null;
      institute = null;
      loading = false;
      _notify();
      return;
    }
    if (account == null) loading = true;
    _notify();
    try {
      final value = await services.api.me();
      if (_disposed || generation != _generation) return;
      account = value;
      if (!memberships.any((x) => x.instituteId == institute))
        institute = memberships.length == 1
            ? memberships.first.instituteId
            : null;
    } on AppFailure catch (e) {
      if (_disposed || generation != _generation) return;
      error = e;
      if (e.status == 401) {
        await signOut();
        return;
      }
    } catch (_) {
      if (_disposed || generation != _generation) return;
      error = const AppFailure('Could not load your account. Please retry.');
    }
    if (_disposed || generation != _generation) return;
    loading = false;
    _notify();
  }

  Future<void> signIn(String email, String password) async {
    try {
      await services.client.auth.signInWithPassword(
        email: email.trim(),
        password: password,
      );
      await load();
    } on AuthException {
      throw const AppFailure(
        'Email or password is incorrect, or the account is not confirmed.',
      );
    } catch (e) {
      if (e is AppFailure) rethrow;
      throw const AppFailure(
        'Could not sign in. Check your connection and retry.',
      );
    }
  }

  Future<void> signOut() async {
    ++_generation;
    account = null;
    institute = null;
    error = null;
    loading = false;
    services.api.clear();
    try {
      await services.clearPrivateMedia?.call();
    } catch (_) {}
    try {
      await services.client.auth.signOut(scope: SignOutScope.local);
    } catch (_) {
      await services.storage.removePersistedSession();
    }
    _notify();
  }

  void selectInstitute(String id) {
    if (!memberships.any((m) => m.instituteId == id)) return;
    services.api.clear();
    institute = id;
    _notify();
  }

  @override
  void dispose() {
    services.api.onSessionLost = null;
    _disposed = true;
    ++_generation;
    _subscription?.cancel();
    super.dispose();
  }
}
