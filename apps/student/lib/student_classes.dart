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
        title: 'Join an attendance class',
        button: 'Send request',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Ask your teacher for the class join code. Your request needs their approval.',
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
  Widget build(BuildContext context) => ContentPage(
    children: [
      PageHeader(
        title: 'Your attendance classes',
        subtitle: 'Join a class and follow your membership requests.',
        eyebrow: 'STUDENT SPACE',
        icon: Icons.school_outlined,
        action: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () => controller.load(),
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
            FilledButton.icon(
              onPressed: join,
              icon: const Icon(Icons.add),
              label: const Text('Join class'),
            ),
          ],
        ),
      ),
      PagedList(
        controller: controller,
        emptyTitle: 'No classes yet',
        emptyMessage:
            'Enter a join code from your teacher to request membership.',
        item: (Enrollment e) => Panel(
          accent: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary
                          .withValues(alpha: .08),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      Icons.menu_book_outlined,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          e.offering!.title,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          e.offering!.subtitle,
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                e.offering!.termCode,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              StatusBadge(e.status),
              const SizedBox(height: 12),
              Text(switch (e.status) {
                'requested' => 'Your teacher needs to approve this request. You do not need to send it again.',
                'active' => 'Your class membership is approved. Face enrolment is reviewed separately.',
                'rejected' => 'Your teacher declined this request.',
                'withdrawn' => 'Your membership in this class has ended.',
                _ => 'Refresh to check your membership status.',
              }),
              if (e.reason != null && e.reason!.isNotEmpty)
                Text('Teacher note: ${e.reason}'),
              if (e.status == 'active')
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: OutlinedButton.icon(
                    onPressed: () => context.go('/classes/${e.offeringId}'),
                    icon: const Icon(Icons.arrow_forward),
                    label: const Text('View attendance'),
                  ),
                ),
              if (['rejected', 'withdrawn'].contains(e.status))
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    'Contact your teacher if you need to rejoin this class.',
                  ),
                ),
            ],
          ),
        ),
      ),
    ],
  );
}
