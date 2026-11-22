import 'package:facetrack_core/facetrack_core.dart' show AppRadius, AppSpace, AppTone;
import 'package:facetrack_models/facetrack_models.dart';
import 'package:flutter/material.dart';

/// What the server says recognition is doing for a session.
class ProcessingInfo {
  const ProcessingInfo({
    this.state = 'idle',
    this.stage,
    this.percent,
    this.waiting = 0,
    this.running = 0,
    this.done = 0,
    this.failed = 0,
    this.total = 0,
    this.oldestWaitSeconds = 0,
    this.workerOnline = true,
  });

  /// idle, waiting, running or stalled.
  final String state;
  final String? stage;
  final int? percent;
  final int waiting, running, done, failed, total, oldestWaitSeconds;
  final bool workerOnline;

  factory ProcessingInfo.fromJson(Object? json) {
    if (json is! Map) return const ProcessingInfo();
    int n(String key) => (json[key] as num?)?.toInt() ?? 0;
    return ProcessingInfo(
      state: json['state'] as String? ?? 'idle',
      stage: json['stage'] as String?,
      percent: (json['percent'] as num?)?.toInt(),
      waiting: n('waiting'),
      running: n('running'),
      done: n('done'),
      failed: n('failed'),
      total: n('total'),
      oldestWaitSeconds: n('oldest_wait_seconds'),
      workerOnline: json['worker_online'] as bool? ?? true,
    );
  }

  bool get stalled => state == 'stalled';
  bool get active => state == 'running' || state == 'waiting' || state == 'stalled';

  /// Segments finished, running or still queued, counted from one.
  int get currentSegment => (done + failed + 1).clamp(1, total == 0 ? 1 : total);
}

enum ProgressState { done, active, pending, warning }

class ProgressStep {
  const ProgressStep(this.label, this.state, {this.detail});
  final String label;
  final ProgressState state;
  final String? detail;
}

const _labels = [
  'Uploading segments',
  'Preparing videos',
  'Detecting faces',
  'Recognizing students',
  'Matching attendance',
  'Finalizing results',
];
const _serverStages = ['preparing', 'detecting', 'recognizing', 'matching', 'finalizing'];

/// The six stages a teacher sees, with the current one marked. Returns an empty list when there
/// is nothing to show (no uploads in flight and nothing queued or running).
List<ProgressStep> progressSteps(ProcessingInfo info, {required int uploading}) {
  int? active;
  var warning = false;
  String? detail;
  if (uploading > 0) {
    active = 0;
    detail = '$uploading segment${uploading == 1 ? '' : 's'} left to send';
  } else if (info.state == 'running') {
    active = 1 + _serverStages.indexOf(info.stage ?? 'preparing').clamp(0, 4);
    if (info.percent != null && active >= 2 && active <= 3) detail = '${info.percent}%';
  } else if (info.state == 'waiting' || info.state == 'stalled') {
    active = 1;
    warning = info.stalled;
    detail = info.stalled ? 'No processing worker is running' : 'Waiting for its turn';
  } else if (info.total > 0 && info.failed < info.total) {
    return [for (final l in _labels) ProgressStep(l, ProgressState.done)];
  } else {
    return const [];
  }
  return [
    for (var i = 0; i < _labels.length; i++)
      ProgressStep(
        _labels[i],
        i < active
            ? ProgressState.done
            : i == active
            ? (warning ? ProgressState.warning : ProgressState.active)
            : ProgressState.pending,
        detail: i == active ? detail : null,
      ),
  ];
}

/// 0 to 1 across all segments, so a long class shows steady movement.
double overallProgress(ProcessingInfo info) {
  if (info.total == 0) return 0;
  var current = 0.0;
  if (info.state == 'running') {
    final p = (info.percent ?? 0) / 100;
    current = switch (info.stage) {
      'detecting' => .05 + .45 * p,
      'recognizing' => .5 + .3 * p,
      'matching' => .85,
      'finalizing' => .95,
      _ => .05,
    };
  }
  return ((info.done + info.failed + current) / info.total).clamp(0, 1).toDouble();
}

/// The reason to show when processing is not moving, or null when all is well.
String? processingProblem(ProcessingInfo info) {
  if (info.stalled) {
    return 'Processing is not running right now. Your recordings are saved and will be processed '
        'as soon as it is back. Tell your administrator if this stays.';
  }
  if (info.state == 'waiting' && info.oldestWaitSeconds >= 180) {
    return 'Processing is busy. ${info.waiting} segment${info.waiting == 1 ? ' is' : 's are'} waiting their turn, '
        'so this is taking longer than usual.';
  }
  if (info.failed > 0) {
    return '${info.failed} segment${info.failed == 1 ? '' : 's'} could not be processed. '
        'Record that part of the room again.';
  }
  return null;
}

/// A short, one-line summary for over the camera: "Segment 2 of 5 · Detecting faces 40%".
String processingSummary(ProcessingInfo info, {required int uploading}) {
  if (uploading > 0) return 'Uploading · $uploading left';
  if (info.state == 'running') {
    final steps = progressSteps(info, uploading: 0);
    final step = steps.firstWhere((s) => s.state == ProgressState.active, orElse: () => steps.first);
    final detail = step.detail == null ? '' : ' ${step.detail}';
    return 'Segment ${info.currentSegment} of ${info.total} · ${step.label}$detail';
  }
  if (info.state == 'stalled') return 'Processing is not running';
  if (info.state == 'waiting') return '${info.waiting} segment${info.waiting == 1 ? '' : 's'} waiting to process';
  return '';
}

/// The six stages as a list, for the finish screen and the session page.
class ProcessingProgress extends StatelessWidget {
  const ProcessingProgress({
    super.key,
    required this.info,
    this.uploading = 0,
    this.onDark = false,
    this.reference,
  });
  final ProcessingInfo info;
  final int uploading;
  final bool onDark;

  /// Short id the teacher can read out so the administrator can find this session in the logs.
  final String? reference;

  @override
  Widget build(BuildContext context) {
    final steps = progressSteps(info, uploading: uploading);
    if (steps.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final ink = onDark ? Colors.white : theme.colorScheme.onSurface;
    final soft = onDark ? Colors.white60 : theme.colorScheme.onSurfaceVariant;
    final problem = processingProblem(info);
    final finished = steps.every((s) => s.state == ProgressState.done);
    final attention = problem != null;
    final (IconData headIcon, String headline, Color headTone) = finished
        ? (Icons.verified_outlined, 'Processing complete', AppTone.success)
        : attention
        ? (Icons.warning_amber_rounded, 'Processing needs attention', AppTone.warning)
        : (Icons.auto_awesome_outlined, 'Processing your recordings', AppTone.info);
    return Column(
      key: const ValueKey('processing-progress'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(headIcon, size: 20, color: onDark && !attention ? Colors.white70 : headTone),
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  headline,
                  style: TextStyle(color: ink, fontWeight: FontWeight.w800, fontSize: 16),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.md),
        if (info.total > 0 && !finished) ...[
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    key: const ValueKey('overall-progress'),
                    value: overallProgress(info),
                    minHeight: 8,
                    backgroundColor: onDark ? Colors.white24 : null,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${info.currentSegment > info.total ? info.total : info.currentSegment} of ${info.total}',
                style: TextStyle(color: soft, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            'Current segment',
            style: TextStyle(color: soft, fontSize: 12),
          ),
          const SizedBox(height: AppSpace.md),
        ],
        for (final step in steps)
          Container(
            margin: const EdgeInsets.symmetric(vertical: 2),
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: 6),
            decoration: BoxDecoration(
              color: switch (step.state) {
                ProgressState.active => AppTone.tint(onDark ? Colors.white : AppTone.info, .10),
                ProgressState.warning => AppTone.tint(Colors.amber, .16),
                _ => Colors.transparent,
              },
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _StepIcon(step.state, onDark: onDark),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text.rich(
                      TextSpan(
                        text: step.label,
                        style: TextStyle(
                          color: step.state == ProgressState.pending ? soft : ink,
                          fontWeight: step.state == ProgressState.active || step.state == ProgressState.warning
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                        children: [
                          if (step.detail != null)
                            TextSpan(
                              text: '  ${step.detail}',
                              style: TextStyle(
                                color: step.state == ProgressState.warning ? Colors.amber.shade700 : soft,
                                fontWeight: FontWeight.w400,
                                fontSize: 13,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (problem != null) ...[
          const SizedBox(height: AppSpace.sm),
          Container(
            key: const ValueKey('processing-problem'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: onDark ? .12 : .16),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.amber.withValues(alpha: .5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(problem, style: TextStyle(color: ink, height: 1.4)),
                if (reference != null && (info.stalled || info.failed > 0))
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('Reference: $reference', style: TextStyle(color: soft, fontSize: 12)),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _StepIcon extends StatelessWidget {
  const _StepIcon(this.state, {required this.onDark});
  final ProgressState state;
  final bool onDark;
  @override
  Widget build(BuildContext context) {
    final soft = onDark ? Colors.white38 : Colors.black38;
    return SizedBox.square(
      dimension: 22,
      child: switch (state) {
        ProgressState.done => const Icon(Icons.check_circle, size: 22, color: Color(0xff2f9e74)),
        ProgressState.active => const Padding(
          padding: EdgeInsets.all(2),
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
        ProgressState.warning => Icon(Icons.warning_amber_rounded, size: 22, color: Colors.amber.shade700),
        ProgressState.pending => Icon(Icons.radio_button_unchecked, size: 22, color: soft),
      },
    );
  }
}

/// Used for lists of rows elsewhere; kept here so the shape of the server's block is in one place.
ProcessingInfo processingFrom(Json data) => ProcessingInfo.fromJson(data['processing']);
