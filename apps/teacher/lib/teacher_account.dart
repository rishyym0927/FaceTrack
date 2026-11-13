import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';

import 'teacher_dashboard.dart';

/// Faculty statistics on the Account page, from the same per-subject
/// summaries as the home dashboard.
class TeacherAccountStats extends ConsumerStatefulWidget {
  const TeacherAccountStats({super.key});
  @override
  ConsumerState<TeacherAccountStats> createState() =>
      _TeacherAccountStatsState();
}

class _TeacherAccountStatsState extends ConsumerState<TeacherAccountStats> {
  List<SubjectStats>? subjects;
  bool failed = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final api = ref.read(servicesProvider).api;
    final institute = ref.read(authProvider).institute!;
    try {
      final stats = <SubjectStats>[];
      String? cursor;
      var pages = 0;
      do {
        final page = await api.send(
          'GET',
          '/v1/teacher/attendance-dashboard',
          institute: institute,
          query: {'cursor': ?cursor},
        );
        for (final item in (page['items'] as List).cast<Json>()) {
          stats.add(SubjectStats(
            Offering.fromJson(item['offering'] as Json),
            summary: item['summary'] as Json,
          ));
        }
        cursor = page['next_cursor'] as String?;
      } while (cursor != null && ++pages < 10);
      if (mounted) setState(() => subjects = stats);
    } catch (_) {
      if (mounted) setState(() => failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (failed) {
      return Panel(
        child: MessageView(
          title: 'Statistics unavailable',
          message: 'Your subjects could not be loaded.',
          action: TextButton(
            onPressed: () {
              setState(() => failed = false);
              load();
            },
            child: const Text('Retry'),
          ),
        ),
      );
    }
    final list = subjects;
    if (list == null) return const SkeletonCard();
    final t = DashboardTotals(list);
    final present = list.fold<int>(0, (n, s) => n + s.attended);
    final absent = list.fold<int>(0, (n, s) => n + s.absent);
    return Panel(
      accent: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Teaching at a glance',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              TextButton(
                onPressed: () => context.go('/classes'),
                child: const Text('Open dashboard'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 20,
            runSpacing: 16,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              PercentRing(value: t.overall, size: 104, caption: 'overall'),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: StatGrid(
                  minTileWidth: 120,
                  children: [
                    StatTile(
                      label: 'Subjects',
                      value: list.length,
                      icon: Icons.menu_book_outlined,
                    ),
                    StatTile(
                      label: 'Classes held',
                      value: t.classes,
                      icon: Icons.event_available_outlined,
                    ),
                    StatTile(
                      label: 'Students',
                      value: t.students,
                      icon: Icons.groups_outlined,
                    ),
                    StatTile(
                      label: 'Below $attendanceThreshold%',
                      value: t.atRiskStudents,
                      accent: const Color(0xffa22f2f),
                      icon: Icons.trending_down,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'Marked across your subjects: Present $present · Absent $absent',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          if (t.loaded < list.length)
            Text(
              '${list.length - t.loaded} subject(s) could not be loaded.',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    );
  }
}
