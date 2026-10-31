import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';

import 'student_attendance.dart';

/// Student statistics on the Account page: subjects, overall attendance and
/// face enrolment. Each part loads on its own and fails on its own.
class StudentAccountStats extends ConsumerStatefulWidget {
  const StudentAccountStats({super.key});
  @override
  ConsumerState<StudentAccountStats> createState() =>
      _StudentAccountStatsState();
}

class _StudentAccountStatsState extends ConsumerState<StudentAccountStats> {
  int? subjects;
  AttendanceStats? stats;
  String? face;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final api = ref.read(servicesProvider).api;
    final institute = ref.read(authProvider).institute!;
    Future<T?> attempt<T>(Future<T> Function() f) async {
      try {
        return await f();
      } catch (_) {
        return null;
      }
    }

    final results = await Future.wait([
      attempt(() async {
        var count = 0, pages = 0;
        String? cursor;
        do {
          final page = await api.enrollments(institute, cursor: cursor);
          count += page.items.where((e) => e.status == 'active').length;
          cursor = page.nextCursor;
        } while (cursor != null && ++pages < 5);
        return count;
      }),
      attempt(
        () async => AttendanceStats(
          await fetchAllPages(api, '/v1/me/attendance', institute),
        ),
      ),
      attempt(() async {
        final state = BiometricState.fromJson(
          await api.send(
            'GET',
            '/v1/me/biometric-enrollment',
            institute: institute,
          ),
        );
        if (state.active) return 'active';
        return state.attempt?.status ?? 'none';
      }),
    ]);
    if (!mounted) return;
    setState(() {
      subjects = results[0] as int?;
      stats = results[1] as AttendanceStats?;
      face = results[2] as String?;
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const SkeletonCard();
    final s = stats;
    return Panel(
      accent: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'At a glance',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              TextButton(
                onPressed: () => context.go('/attendance'),
                child: const Text('View attendance'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 20,
            runSpacing: 16,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              PercentRing(value: s?.percentage, size: 104, caption: 'overall'),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: StatGrid(
                  minTileWidth: 120,
                  children: [
                    StatTile(
                      label: 'Subjects',
                      value: subjects ?? 0,
                      icon: Icons.menu_book_outlined,
                      caption: subjects == null ? 'Could not load' : null,
                    ),
                    StatTile(
                      label: 'Present',
                      value: s?.present ?? 0,
                      accent: const Color(0xff176451),
                      icon: Icons.check_circle_outline,
                    ),
                    StatTile(
                      label: 'Absent',
                      value: s?.absent ?? 0,
                      accent: const Color(0xffa22f2f),
                      icon: Icons.cancel_outlined,
                    ),
                    StatTile(
                      label: 'Unassessed',
                      value: s?.unassessed ?? 0,
                      accent: const Color(0xff9a6a00),
                      icon: Icons.help_outline,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              face == 'active' ? Icons.verified_outlined : Icons.face_outlined,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: const Text('Face enrolment'),
            subtitle: Text(
              face == null ? 'Could not load' : biometricStatus(face!),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/enrolment'),
          ),
        ],
      ),
    );
  }
}
