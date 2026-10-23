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
  @override
  void initState() {
    super.initState();
    api = ref.read(servicesProvider).api;
    institute = ref.read(authProvider).institute!;
    controller = PagedController((cursor) async {
      final result = await api.send(
        'GET',
        '/v1/me/attendance',
        institute: institute,
        query: {
          'offering_id': widget.offering,
          'cursor': ?cursor,
        },
      );
      summary = result['summary'];
      return PageData.fromJson(result, (j) => j);
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
        title: 'Your published attendance',
        subtitle: 'Only teacher-published decisions appear here. Processing suggestions are not final attendance.',
        action: OutlinedButton(
          onPressed: () => controller.load(),
          child: const Text('Refresh'),
        ),
      ),
      AnimatedBuilder(
        animation: controller,
        builder: (c, _) => summary == null
            ? const SizedBox()
            : Panel(
                child: Text(
                  summary!['percentage'] == null
                      ? 'No assessed sessions yet. Unassessed and excused results do not count toward a percentage.'
                      : '${(summary!['percentage'] as num).toStringAsFixed(1)}% · ${summary!['present_or_late']} present or late / ${summary!['assessed']} assessed · ${summary!['unassessed']} unassessed',
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
                Text(
                  '${r['status'][0].toUpperCase()}${r['status'].substring(1)}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
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
