import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
          summary = result['summary'];
          try {
            final disputeResult = await api.send(
              'GET',
              '/v1/me/attendance-disputes',
              institute: institute,
              query: {'limit': 200},
            );
            if (mounted && current == summaryGeneration) {
              disputes = (disputeResult['items'] as List).cast<Json>();
            }
          } on AppFailure {
            // The published marks remain available when query history fails.
          }
        }
        return PageData<Json>.fromJson(result, (row) => row);
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
              'Explain why this published Absent result should be reviewed. Your assigned faculty will decide and any accepted correction creates a new publication.',
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
            content: Text('Attendance query sent to your faculty.'),
          ),
        );
      }
    }
  }

  Widget _summaryBody(BuildContext context, Json summary) {
    final pct = summary['percentage'];
    final present = summary['present_or_late'] as num? ?? 0;
    final assessed = summary['assessed'] as num? ?? 0;
    final ring = PercentRing(
      value: pct is num ? pct.toDouble() : null,
      size: 128,
      caption: 'attendance',
    );
    final tiles = StatGrid(
      minTileWidth: 124,
      children: [
        StatTile(
          label: 'Present',
          value: present,
          accent: const Color(0xff176451),
          icon: Icons.check_circle_outline,
        ),
        StatTile(
          label: 'Absent',
          value: assessed - present,
          accent: const Color(0xffa22f2f),
          icon: Icons.cancel_outlined,
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, box) => box.maxWidth >= 460
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                ring,
                const SizedBox(width: 20),
                Expanded(child: tiles),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(child: ring),
                const SizedBox(height: 16),
                tiles,
              ],
            ),
    );
  }

  @override
  Widget build(BuildContext context) => ContentPage(
    onRefresh: () => controller.load(),
    children: [
      TextButton.icon(
        onPressed: () => goBack(context, '/classes'),
        icon: const Icon(Icons.arrow_back),
        label: const Text('Your subjects'),
      ),
      PageHeader(
        compact: true,
        title: 'Your published attendance',
        subtitle: 'Only faculty-published decisions appear here. Processing suggestions are not final attendance.',
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
                      const SizedBox(height: 16),
                      _summaryBody(context, summary!),
                    ],
                  ),
                ),
              ),
      ),
      PagedList<Json>(
        controller: controller,
        emptyTitle: 'No published attendance yet',
        emptyMessage: 'Your faculty must review and publish a session before it appears here.',
        item: (r) {
          final mark = finalStatus(r['status'] as String?);
          if (!finalStatuses.contains(mark)) return const SizedBox.shrink();
          final d = DateTime.parse(r['starts_at']).toLocal(),
              l = MaterialLocalizations.of(context);
          // Match by session, not by publication id: an accepted correction
          // supersedes the original Absent publication with a new id, so a
          // publication-id match would drop the query note after resolution.
          // disputes arrive newest-first, so the first match is the latest.
          Json? query;
          for (final item in disputes) {
            if (item['session_id'] == r['session_id']) {
              query = item;
              break;
            }
          }
          return Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${l.formatMediumDate(d)} · ${l.formatTimeOfDay(TimeOfDay.fromDateTime(d))}',
                ),
                const SizedBox(height: 12),
                StatusBadge(mark),
                const SizedBox(height: 12),
                if ((r['revision'] as num? ?? 1) > 1)
                  const Row(
                    children: [
                      Icon(Icons.edit_note, size: 18),
                      SizedBox(width: 6),
                      Text('Corrected by faculty'),
                    ],
                  ),
                if (r['reason'] != null) Text('Faculty note: ${r['reason']}'),
                if (query != null) ...[
                  const SizedBox(height: 12),
                  StatusBadge(query['status']),
                  Text(switch (query['status']) {
                    'open' =>
                      'Your attendance query is waiting for faculty review.',
                    'accepted' => 'Your query was accepted and a corrected publication was created.',
                    'rejected' =>
                      'Your faculty reviewed and declined this query.',
                    _ => 'This query is closed.',
                  }),
                  if (query['resolution_reason'] != null)
                    Text('Faculty response: ${query['resolution_reason']}'),
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
