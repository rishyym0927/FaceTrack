import 'package:facetrack_core/facetrack_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Attendance details live in the dedicated tab, so Account needs no
/// duplicate dashboard request or potentially stale copy of its numbers.
class TeacherAccountStats extends StatelessWidget {
  const TeacherAccountStats({super.key});

  @override
  Widget build(BuildContext context) => Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Attendance', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        const Text('View published results and students below 75%.'),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () => context.go('/attendance'),
          icon: const Icon(Icons.insights_outlined),
          label: const Text('Open attendance'),
        ),
      ],
    ),
  );
}
