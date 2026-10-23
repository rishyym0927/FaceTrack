import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:facetrack_capture/facetrack_capture.dart';
import 'package:facetrack_core/facetrack_core.dart';

import 'student_classes.dart';
import 'student_enrolment.dart';
import 'student_history.dart';

final List<Object> resources = [];
void main() => launchProduct(
  AppConfig.environment(AppRole.student),
  classesBuilder: (_) => const StudentClasses(),
  detailBuilder: (_, id) => StudentHistory(offering: id),
  enrollmentBuilder: (_) => const StudentEnrolment(),
  configure: (services) async {
    services.clearPrivateMedia = PendingClips.clear;
    Future<void> cleanup() =>
        PendingClips.expire(owner: services.client.auth.currentUser?.id);
    await cleanup();
    resources.add(AppLifecycleListener(onResume: () => unawaited(cleanup())));
    resources.add(
      Timer.periodic(const Duration(minutes: 5), (_) => unawaited(cleanup())),
    );
  },
);
