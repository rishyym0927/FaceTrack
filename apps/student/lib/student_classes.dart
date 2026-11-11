import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';

class StudentClasses extends ConsumerStatefulWidget {
  const StudentClasses({super.key});
  @override
  ConsumerState<StudentClasses> createState() => _StudentClassesState();
}

class _StudentClassesState extends ConsumerState<StudentClasses>
    with ResumeRefresh<StudentClasses> {
  late final ApiClient api;
  late final String institute;
  late final PagedController<Enrollment> controller;
  @override
  void initState() {
    super.initState();
    api = ref.read(servicesProvider).api;
    institute = ref.read(authProvider).institute!;
    controller = PagedController(
      (cursor) => api.enrollments(institute, cursor: cursor),
    );
    controller.load();
    watchLifecycle();
  }

  @override
  void refreshOnResume() {
    controller.load();
  }

  @override
  void dispose() {
    unwatchLifecycle();
    controller.dispose();
    super.dispose();
  }

  Future<void> join() async {
    final code = TextEditingController();
    await showDialog<bool>(
      context: context,
      builder: (_) => ActionDialog(
        title: 'Join a subject',
        button: 'Send request',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Ask your faculty for the subject join code. Your request needs their approval.',
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: code,
              autofocus: true,
              maxLength: 40,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Join code',
                hintText: 'XXXX-XXXX-XXXX',
              ),
              validator: requiredText,
            ),
          ],
        ),
        submit: (mutation) async {
          await api.send(
            'POST',
            '/v1/enrollment-requests',
            institute: institute,
            body: {'join_code': code.text.trim()},
            mutation: mutation,
          );
        },
      ),
    );
    code.dispose();
    if (mounted) await controller.load();
  }

  @override
  Widget build(BuildContext context) {
    return ContentPage(
      onRefresh: () => controller.load(),
      children: [
        PageHeader(
          title: 'Subjects',
          action: Wrap(
            spacing: 8,
            children: [
              FilledButton.icon(
                onPressed: join,
                icon: const Icon(Icons.add),
                label: const Text('Join subject'),
              ),
              IconButton(
                tooltip: 'Refresh subjects',
                onPressed: () => controller.load(),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        const AttentionCard(hideWhenIdle: true),
        PagedList(
          controller: controller,
          emptyTitle: 'No subjects yet',
          emptyMessage:
              'Enter a join code from your faculty to request membership.',
          item: (Enrollment e) => SubjectTile(
            title: e.offering!.title,
            subtitle: e.offering!.subtitle,
            status: e.status == 'active' ? null : e.status,
            note: switch (e.status) {
              'requested' => 'Waiting for faculty approval.',
              'rejected' =>
                e.reason != null && e.reason!.isNotEmpty
                    ? 'Declined: ${e.reason}'
                    : 'Declined. Contact your faculty to rejoin.',
              'withdrawn' =>
                'Membership ended. Contact your faculty to rejoin.',
              _ => null,
            },
            onTap: e.status == 'active'
                ? () => context.push('/classes/${e.offeringId}')
                : null,
          ),
        ),
      ],
    );
  }
}
