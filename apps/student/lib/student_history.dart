import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';

class StudentHistory extends ConsumerStatefulWidget {
  const StudentHistory({super.key, required this.offering});
  final String offering;
  @override
  ConsumerState<StudentHistory> createState() => _StudentHistoryState();
}

class _StudentHistoryState extends ConsumerState<StudentHistory>
    with ResumeRefresh<StudentHistory> {
  late final ApiClient api;
  late final String institute;
  late final PagedController<Json> controller;
  Json? summary;
  int summaryGeneration = 0;
  @override
  void initState() {
    super.initState();
    api = ref.read(servicesProvider).api;
    institute = ref.read(authProvider).institute!;
    controller = PagedController((cursor) async {
      final current = ++summaryGeneration;
      try {
        final result = await api.send(
          'GET',
          '/v1/me/attendance',
          institute: institute,
          query: {'offering_id': widget.offering, 'cursor': ?cursor},
        );
        if (mounted && current == summaryGeneration) {
          summary = result['summary'];
        }
        return PageData.fromJson(result, (j) => j);
      } on AppFailure catch (e) {
        if (mounted &&
            current == summaryGeneration &&
            [401, 403, 404].contains(e.status)) {
          summary = null;
        }
        rethrow;
      }
    });
    controller.load();
    watchLifecycle();
  }

  @override
  void refreshOnResume() => controller.load();
  @override
  void dispose() {
    unwatchLifecycle();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ContentPage(
    children: [
      TextButton.icon(
        onPressed: () => context.go('/classes'),
        icon: const Icon(Icons.arrow_back),
        label: const Text('Your classes'),
      ),
      PageHeader(
        compact: true,
        title: 'Your published attendance',
        subtitle: 'Only teacher-published decisions appear here. Processing suggestions are not final attendance.',
        eyebrow: 'ATTENDANCE HISTORY',
        icon: Icons.fact_check_outlined,
        action: OutlinedButton(
          onPressed: () => controller.load(),
          child: const Text('Refresh'),
        ),
      ),
      AnimatedBuilder(
        animation: controller,
        builder: (c, _) => summary == null
            ? const SizedBox()
            : Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Panel(
                  accent: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Published attendance overview',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      if (summary!['percentage'] != null) ...[
                        Text(
                          '${(summary!['percentage'] as num).toStringAsFixed(1)}%',
                          style: Theme.of(context).textTheme.displaySmall
                              ?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${summary!['present_or_late']} present or late · ${summary!['assessed']} assessed · ${summary!['unassessed']} unassessed',
                        ),
                      ] else
                        const Text('No assessed sessions yet.'),
                      const SizedBox(height: 8),
                      const Text(
                        'Unassessed and excused results are excluded from the percentage.',
                      ),
                    ],
                  ),
                ),
              ),
      ),
      PagedList<Json>(
        controller: controller,
        emptyTitle: 'No published attendance yet',
        emptyMessage: 'Your teacher must review and publish a session before it appears here.',
        item: (r) {
          final d = DateTime.parse(r['starts_at']).toLocal(),
              l = MaterialLocalizations.of(context);
          return Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${l.formatMediumDate(d)} · ${l.formatTimeOfDay(TimeOfDay.fromDateTime(d))}',
                ),
                const SizedBox(height: 12),
                StatusBadge(r['status']),
                const SizedBox(height: 12),
                Text('Publication revision ${r['revision']}'),
                if (r['reason'] != null) Text('Teacher note: ${r['reason']}'),
              ],
            ),
          );
        },
      ),
    ],
  );
}
