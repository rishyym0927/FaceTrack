import 'package:flutter/foundation.dart';

enum AppRole { student, teacher }

class AppConfig {
  const AppConfig({
    required this.role,
    required this.apiUrl,
    required this.supabaseUrl,
    required this.publishableKey,
    required this.defaultInstituteId,
  });
  factory AppConfig.environment(AppRole role) => AppConfig(
    role: role,
    apiUrl: const String.fromEnvironment(
      'API_BASE_URL',
      defaultValue: 'http://127.0.0.1:8000',
    ),
    supabaseUrl: const String.fromEnvironment('SUPABASE_URL'),
    publishableKey: const String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY'),
    defaultInstituteId: const String.fromEnvironment('DEFAULT_INSTITUTE_ID'),
  );
  final AppRole role;
  final String apiUrl, supabaseUrl, publishableKey, defaultInstituteId;
  String get roleName => role.name;
  String get title =>
      'FaceTrack ' + (role == AppRole.student ? 'Student' : 'Teacher');
  String get storageKey =>
      'facetrack.' + role.name + '.' + Uri.parse(supabaseUrl).host + '.auth';
  void validate() {
    final api = Uri.tryParse(apiUrl), supabase = Uri.tryParse(supabaseUrl);
    final local = api != null && ['localhost', '127.0.0.1'].contains(api.host);
    if (api == null ||
        api.userInfo.isNotEmpty ||
        api.hasQuery ||
        api.hasFragment ||
        (api.scheme != 'https' &&
            !(api.scheme == 'http' && local && (!kReleaseMode || kIsWeb))) ||
        supabase == null ||
        supabase.scheme != 'https' ||
        supabase.host.isEmpty ||
        supabase.userInfo.isNotEmpty ||
        !publishableKey.startsWith('sb_publishable_') ||
        !RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(defaultInstituteId)) {
      throw const FormatException('Application configuration is incomplete.');
    }
  }
}
