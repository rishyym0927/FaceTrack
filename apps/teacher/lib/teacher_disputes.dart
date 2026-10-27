import 'package:flutter/material.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';

class TeacherDisputes extends StatefulWidget {
  const TeacherDisputes({
    super.key,
    required this.api,
    required this.institute,
    required this.offering,
  });
  final ApiClient api;
  final String institute, offering;

  @override
  State<TeacherDisputes> createState() => _TeacherDisputesState();
}

class _TeacherDisputesState extends State<TeacherDisputes> {
  late final PagedController<Json> controller;

  @override
  void initState() {
    super.initState();
    controller = PagedController((cursor) async {
      final result = await widget.api.send(
        'GET',
        '/v1/offerings/${widget.offering}/attendance-disputes',
        institute: widget.institute,
        query: {'status': 'open', 'cursor': ?cursor},
      );
      return PageData.fromJson(result, (json) => json);
    })..load();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> resolve(Json row, String decision) async {
    final reason = TextEditingController();
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => ActionDialog(
        title: decision == 'accepted'
            ? 'Accept attendance query'
            : 'Reject attendance query',
        button: decision == 'accepted'
            ? 'Accept and publish correction'
            : 'Reject query',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${row['official_name']} · ${row['enrollment_number']}'),
            const SizedBox(height: 8),
            Text('Student reason: ${row['student_reason']}'),
            const SizedBox(height: 16),
            TextFormField(
              controller: reason,
              minLines: 3,
              maxLines: 5,
              maxLength: 1000,
              validator: (value) => (value?.trim().length ?? 0) < 3
                  ? 'Enter a clear response.'
                  : null,
              decoration: const InputDecoration(labelText: 'Faculty response'),
            ),
          ],
        ),
        submit: (mutation) async {
          await widget.api.send(
            'POST',
            '/v1/attendance-disputes/${row['id']}/resolve',
            institute: widget.institute,
            version: row['version'],
            mutation: mutation,
            body: {'decision': decision, 'reason': reason.text.trim()},
          );
        },
      ),
    );
    reason.dispose();
    if (changed == true) {
      await controller.load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              decision == 'accepted'
                  ? 'Query accepted. Corrected attendance and reports are being prepared.'
                  : 'Query rejected with your response.',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => PagedList<Json>(
    controller: controller,
    emptyTitle: 'No open attendance queries',
    emptyMessage:
        'Student queries about published Absent results will appear here.',
    item: (row) {
      final date = DateTime.parse(row['starts_at']).toLocal();
      return Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${row['official_name']} · ${row['enrollment_number']}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(MaterialLocalizations.of(context).formatMediumDate(date)),
            const SizedBox(height: 8),
            Text('Student reason: ${row['student_reason']}'),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: () => resolve(row, 'accepted'),
                  child: const Text('Accept and correct'),
                ),
                OutlinedButton(
                  onPressed: () => resolve(row, 'rejected'),
                  child: const Text('Reject with reason'),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}
