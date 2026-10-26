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
  List<Json> disputes = [];
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
          final disputeResult = await api.send(
            'GET',
            '/v1/me/attendance-disputes',
            institute: institute,
            query: {'limit': 200},
          );
          if (!mounted || current != summaryGeneration) {
            return PageData.fromJson(result, (j) => j);
          }
          summary = result['summary'];
          disputes = (disputeResult['items'] as List).cast<Json>();
        }
        return PageData.fromJson(result, (j) => j);
      } on AppFailure catch (e) {
        if (mounted &&
            current == summaryGeneration &&
            [401, 403, 404].contains(e.status)) {
          summary = null;
          disputes = [];
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

  Future<void> raiseQuery(Json record) async {
    final reason = TextEditingController();
    final submitted = await showDialog<bool>(
      context: context,
      builder: (_) => ActionDialog(
        title: 'Raise an attendance query',
        button: 'Send query',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Explain why this published Absent result should be reviewed. Your assigned teacher will decide and any accepted correction creates a new publication.',
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: reason,
              minLines: 3,
              maxLines: 5,
              maxLength: 1000,
              validator: (value) => (value?.trim().length ?? 0) < 5
                  ? 'Enter at least 5 characters.'
                  : null,
              decoration: const InputDecoration(labelText: 'Reason for review'),
            ),
          ],
        ),
        submit: (mutation) async {
          await api.send(
            'POST',
            '/v1/me/attendance/${record['id']}/disputes',
            institute: institute,
            mutation: mutation,
            body: {'reason': reason.text.trim()},
          );
        },
      ),
    );
    reason.dispose();
    if (submitted == true) {
      await controller.load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Attendance query sent to your teacher.'),
          ),
        );
      }
    }
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
          // Match by session, not by publication id: an accepted correction
          // supersedes the original Absent publication with a new id, so a
          // publication-id match would drop the query note after resolution.
          // disputes arrive ordered oldest-first, so the last match is latest.
          Json? query;
          for (final item in disputes) {
            if (item['session_id'] == r['session_id']) query = item;
          }
          return Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${l.formatMediumDate(d)} · ${l.formatTimeOfDay(TimeOfDay.fromDateTime(d))}',
                ),
                const SizedBox(height: 12),
                StatusBadge(r['status']),
                if (r['assessment_code'] != null) ...[
                  const SizedBox(height: 8),
                  Text(switch (r['assessment_code']) {
                    'recognized' => 'Recognition evidence was available before teacher review.',
                    'not_recognized' => 'The system did not recognize you in the usable capture; your teacher confirmed the final result.',
                    'template_ineligible' => 'Face recognition was unavailable; your teacher assessed this manually.',
                    'limited_capture' => 'Capture coverage was limited; your teacher assessed this manually.',
                    'processing_failed' =>
                      'Processing failed; your teacher assessed this manually.',
                    _ => 'Your teacher reviewed this result.',
                  }),
                ],
                const SizedBox(height: 12),
                Text('Publication revision ${r['revision']}'),
                if (r['reason'] != null) Text('Teacher note: ${r['reason']}'),
                if (query != null) ...[
                  const SizedBox(height: 12),
                  StatusBadge(query['status']),
                  Text(switch (query['status']) {
                    'open' =>
                      'Your attendance query is waiting for teacher review.',
                    'accepted' => 'Your query was accepted and a corrected publication was created.',
                    'rejected' =>
                      'Your teacher reviewed and declined this query.',
                    _ => 'This query is closed.',
                  }),
                  if (query['resolution_reason'] != null)
                    Text('Teacher response: ${query['resolution_reason']}'),
                ] else if (r['status'] == 'absent') ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => raiseQuery(r),
                    icon: const Icon(Icons.chat_bubble_outline),
                    label: const Text('Raise query'),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    ],
  );
}
