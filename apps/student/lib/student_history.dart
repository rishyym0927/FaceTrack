import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';

import 'student_ui.dart';

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
  Offering? subject;
  Map<String, Json> disputes = {};
  bool disputesReady = false, disputeLoadFailed = false;
  int disputeGeneration = 0;
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
        return PageData<Json>.fromJson(result, (row) => row);
      } on AppFailure catch (e) {
        if (mounted &&
            current == summaryGeneration &&
            [401, 403, 404].contains(e.status)) {
          summary = null;
          disputes = {};
          disputesReady = false;
          disputeGeneration++;
        }
        rethrow;
      }
    });
    loadSubject();
    refresh();
    watchLifecycle();
  }

  @override
  void refreshOnResume() => refresh();

  Future<void> loadSubject() async {
    try {
      final loaded = await api.offering(institute, widget.offering);
      if (mounted) setState(() => subject = loaded);
    } catch (_) {
      // Published attendance remains available if the subject label fails.
    }
  }

  Future<void> refresh() async {
    await Future.wait([controller.load(), loadDisputes()]);
  }

  Future<void> loadDisputes() async {
    if (!mounted) return;
    final generation = ++disputeGeneration;
    setState(() {
      disputesReady = disputes.isNotEmpty;
      disputeLoadFailed = false;
    });
    try {
      final latest = <String, Json>{};
      final seenCursors = <String>{};
      String? cursor;
      do {
        final page = await api.send(
          'GET',
          '/v1/me/attendance-disputes',
          institute: institute,
          query: {'limit': 200, 'cursor': ?cursor},
        );
        if (!mounted || generation != disputeGeneration) return;
        for (final query in (page['items'] as List).cast<Json>()) {
          latest.putIfAbsent(query['session_id'] as String, () => query);
        }
        cursor = page['next_cursor'] as String?;
        if (cursor != null && !seenCursors.add(cursor)) {
          throw const AppFailure(
            'The attendance query list could not be completed.',
          );
        }
      } while (cursor != null);
      setState(() {
        disputes = latest;
        disputesReady = true;
      });
    } on AppFailure catch (e) {
      if (!mounted || generation != disputeGeneration) return;
      setState(() {
        if ([401, 403, 404].contains(e.status)) disputes = {};
        disputeLoadFailed = true;
      });
    }
  }

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
    disposeAfterDialog(reason);
    if (submitted == true) {
      await refresh();
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

  Widget _record(BuildContext context, Json r) {
    final mark = finalStatus(r['status'] as String?);
    if (!finalStatuses.contains(mark)) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final d = DateTime.parse(r['starts_at']).toLocal(),
        l = MaterialLocalizations.of(context);
    // Match by session, not by publication id: an accepted correction
    // supersedes the original Absent publication with a new id, so a
    // publication-id match would drop the query note after resolution.
    // disputes arrive newest-first, so the first match is the latest.
    final query = disputes[r['session_id']];
    final present = mark == 'present';
    return Panel(
      padding: 16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, box) {
              // Big text or a narrow card puts the badge under the date.
              final stacked =
                  box.maxWidth < 360 ||
                  MediaQuery.textScalerOf(context).scale(1) > 1.3;
              final dates = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.formatMediumDate(d),
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  Text(
                    l.formatTimeOfDay(TimeOfDay.fromDateTime(d)),
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  if (stacked) ...[
                    const SizedBox(height: 8),
                    StatusBadge(mark),
                  ],
                ],
              );
              return Row(
                crossAxisAlignment: stacked
                    ? CrossAxisAlignment.start
                    : CrossAxisAlignment.center,
                children: [
                  IconTile(
                    present
                        ? Icons.check_circle_outline
                        : Icons.cancel_outlined,
                    color: present ? studentGreen : studentRed,
                    size: 40,
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: dates),
                  if (!stacked) ...[const SizedBox(width: 8), StatusBadge(mark)],
                ],
              );
            },
          ),
          if ((r['revision'] as num? ?? 1) > 1 || r['reason'] != null) ...[
            const SizedBox(height: 12),
            if ((r['revision'] as num? ?? 1) > 1)
              const Row(
                children: [
                  Icon(Icons.edit_note, size: 18),
                  SizedBox(width: 6),
                  Expanded(child: Text('Corrected by faculty')),
                ],
              ),
            if (r['reason'] != null) Text('Faculty note: ${r['reason']}'),
          ],
          if (query != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: scheme.outline),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        'Your query',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      StatusBadge(query['status']),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(switch (query['status']) {
                    'open' =>
                      'Your attendance query is waiting for faculty review.',
                    'accepted' =>
                      'Your query was accepted and a corrected publication was created.',
                    'rejected' =>
                      'Your faculty reviewed and declined this query.',
                    _ => 'This query is closed.',
                  }),
                  if (query['resolution_reason'] != null)
                    Text('Faculty response: ${query['resolution_reason']}'),
                ],
              ),
            ),
          ] else if (disputesReady && r['status'] == 'absent') ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => raiseQuery(r),
                icon: const Icon(Icons.chat_bubble_outline),
                label: const Text('Raise query'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ContentPage(
    onRefresh: refresh,
    children: [
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => goBack(context, '/classes'),
          icon: const Icon(Icons.arrow_back),
          label: const Text('Back to subjects'),
        ),
      ),
      PageHeader(
        title: subject?.title ?? 'Your published attendance',
        subtitle: subject?.subtitle,
        action: OutlinedButton.icon(
          onPressed: refresh,
          icon: const Icon(Icons.refresh),
          label: const Text('Refresh'),
        ),
      ),
      if (disputeLoadFailed) ...[
        InlineNotice(
          'Could not load your attendance queries.',
          icon: Icons.cloud_off_outlined,
          tone: studentAmber,
          onRetry: loadDisputes,
        ),
        const SizedBox(height: 12),
      ],
      // The summary is set while the list loads, so it is rebuilt with the
      // controller to stay in step with the records below it.
      ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final stats = summary;
          if (stats == null) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Panel(
              accent: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Attendance summary',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 16),
                  _summaryBody(context, stats),
                ],
              ),
            ),
          );
        },
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          'Class by class',
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
      PagedList<Json>(
        controller: controller,
        emptyTitle: 'No published attendance yet',
        emptyMessage:
            'Once your faculty reviews and publishes a session, it appears here.',
        item: (r) => _record(context, r),
      ),
    ],
  );
}
