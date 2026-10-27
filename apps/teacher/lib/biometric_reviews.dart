import 'package:flutter/material.dart';
import 'package:facetrack_capture/facetrack_capture.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';

class BiometricReviews extends StatelessWidget {
  const BiometricReviews({
    super.key,
    required this.controller,
    required this.api,
    required this.institute,
  });
  final PagedController<BiometricAttempt> controller;
  final ApiClient api;
  final String institute;
  Future<void> video(BuildContext context, BiometricAttempt attempt) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(attempt.name ?? 'Review face enrolment'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            child: FutureBuilder<Json>(
              future: api.send(
                'GET',
                '/v1/biometric-enrollments/${attempt.id}/review-video',
                institute: institute,
              ),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Text(
                    snapshot.error is AppFailure
                        ? (snapshot.error as AppFailure).message
                        : 'Video unavailable. Close and retry review.',
                  );
                }
                if (!snapshot.hasData) {
                  return const SizedBox(
                    height: 120,
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClipPlayback(url: snapshot.data!['url']),
                    const SizedBox(height: 12),
                    const Text(
                      'Verify this student’s identity and front, up, down, left and right poses. This video does not establish certified liveness.',
                    ),
                  ],
                );
              },
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> decide(
    BuildContext context,
    BiometricAttempt a,
    bool approve,
  ) async {
    bool identity = false, poses = false;
    final reason = TextEditingController();
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setLocal) => ActionDialog(
          title: approve
              ? 'Activate this face enrolment?'
              : 'Request a new recording',
          button: approve ? 'Activate' : 'Reject recording',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(a.name ?? 'Student'),
              const SizedBox(height: 12),
              if (approve) ...[
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'I reviewed the video and confirmed the student’s identity.',
                  ),
                  value: identity,
                  onChanged: (v) => setLocal(() => identity = v ?? false),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'I confirmed front, up, down, left and right poses.',
                  ),
                  value: poses,
                  onChanged: (v) => setLocal(() => poses = v ?? false),
                ),
                const Text(
                  'Activation replaces any previous compatible active template set. Subject membership is unchanged.',
                ),
              ] else
                TextFormField(
                  controller: reason,
                  maxLength: 500,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Reason for a fresh recording',
                  ),
                  validator: requiredText,
                ),
            ],
          ),
          submit: (mutation) async {
            if (approve && (!identity || !poses)) {
              throw const AppFailure(
                'Confirm the identity and all five poses before activation.',
              );
            }
            await api.send(
              'POST',
              '/v1/biometric-enrollments/${a.id}/${approve ? 'approve' : 'reject'}',
              institute: institute,
              version: a.version,
              mutation: mutation,
              body: approve
                  ? {'identity_confirmed': true, 'poses_confirmed': true}
                  : {'reason': reason.text.trim()},
            );
          },
        ),
      ),
    );
    reason.dispose();
    if (changed == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            approve
                ? 'Face enrolment activated. The student can refresh their status.'
                : 'New recording requested. The student can see your reason.',
          ),
        ),
      );
    }
    await controller.load();
  }

  @override
  Widget build(BuildContext context) => PagedList<BiometricAttempt>(
    controller: controller,
    emptyTitle: 'No face enrolments to review',
    emptyMessage: 'Processed videos from approved students in this subject will appear here.',
    item: (a) => Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            a.name ?? 'Student',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text('Enrolment number: ${a.number ?? ''}'),
          Text(
            'Review before ${MaterialLocalizations.of(context).formatMediumDate(a.expiresAt.toLocal())} at ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(a.expiresAt.toLocal()))}',
          ),
          const SizedBox(height: 8),
          Text(qualitySummary(a.quality)),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => video(context, a),
                icon: const Icon(Icons.play_circle_outline),
                label: const Text('Review recording'),
              ),
              FilledButton(
                onPressed: () => decide(context, a, true),
                child: const Text('Approve identity'),
              ),
              TextButton(
                onPressed: () => decide(context, a, false),
                child: const Text('Request new recording'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

String qualitySummary(Json quality) {
  final values = quality['counts'] is Map ? quality['counts'] as Map : quality;
  final parts = <String>[];
  const labels = {
    'sampled_frames': 'Frames checked',
    'detections': 'Face observations',
    'quality_rejects': 'Observations excluded by quality checks',
  };
  for (final entry in labels.entries) {
    if (values[entry.key] is num) {
      parts.add('${entry.value}: ${values[entry.key]}');
    }
  }
  return parts.isEmpty
      ? 'Processing completed. Identity and all five poses still need your review.'
      : '${parts.join(' · ')}. These checks do not measure recognition accuracy.';
}
