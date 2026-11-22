import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'student_notifications.dart' show attendanceThreshold;

String _pct(num value) {
  final text = value.toStringAsFixed(1);
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}

String _classes(int n) => '$n class${n == 1 ? '' : 'es'}';

/// What the future-classes projection from `/v1/me/attendance-projection` means for the student,
/// in one or two plain sentences. Null when there is nothing trustworthy to say (the answer is
/// missing, malformed, or the subject has no timetable).
String? projectionAdvice(Json? p) {
  if (p == null || p['basis'] != 'timetable') return null;
  final remaining = p['remaining'];
  final canMiss = p['max_can_miss'];
  if (remaining is! int || canMiss is! int || remaining < 0 || canMiss < 0) {
    return null;
  }
  final threshold = p['threshold_percent'] is int
      ? p['threshold_percent'] as int
      : attendanceThreshold;
  final waiting = p['awaiting_publication'] is int
      ? p['awaiting_publication'] as int
      : 0;
  final best = p['best_possible_percentage'];
  final String main;
  if (remaining == 0) {
    main = 'No more classes are left on the timetable.';
  } else if (p['reachable'] == false) {
    main =
        'Even if you attend all ${_classes(remaining)} left, you cannot reach $threshold%'
        '${best is num ? ' (best possible ${_pct(best)}%)' : ''}.';
  } else if (canMiss == 0) {
    main =
        'You need to attend all ${_classes(remaining)} left to stay at or above $threshold%.';
  } else {
    main =
        'Of the ${_classes(remaining)} left, you can miss up to $canMiss and still finish at or above $threshold%.';
  }
  return waiting > 0
      ? '$main (Includes ${_classes(waiting)} held but not published yet.)'
      : main;
}

/// Fetches and shows the projection for one subject. It is an extra: while loading, or if the
/// request fails, it shows nothing and never blocks the rest of the page.
class ProjectionNote extends ConsumerStatefulWidget {
  const ProjectionNote({super.key, required this.offeringId});
  final String offeringId;
  @override
  ConsumerState<ProjectionNote> createState() => _ProjectionNoteState();
}

class _ProjectionNoteState extends ConsumerState<ProjectionNote> {
  Json? data;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ProjectionNote old) {
    super.didUpdateWidget(old);
    if (old.offeringId != widget.offeringId) {
      setState(() => data = null);
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final id = widget.offeringId;
    try {
      final result = await ref
          .read(servicesProvider)
          .api
          .send(
            'GET',
            '/v1/me/attendance-projection',
            institute: ref.read(authProvider).institute!,
            query: {'offering_id': id},
          );
      if (!mounted || generation != _generation) return;
      setState(() => data = result);
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() => data = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = projectionAdvice(data);
    if (text == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.event_available_outlined, size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
