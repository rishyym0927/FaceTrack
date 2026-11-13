import 'package:facetrack_core/facetrack_core.dart';

import 'teacher_account.dart';
import 'teacher_admin.dart';
import 'teacher_classes.dart';
import 'classroom_pending.dart';
import 'teacher_notifications.dart';
import 'teacher_sessions.dart';

void main() => launchProduct(
  AppConfig.environment(AppRole.teacher),
  classesBuilder: (_) => const TeacherClasses(),
  sessionBuilder: (_, id) => TeacherSessionDetail(id: id),
  detailBuilder: (_, id) => TeacherClassDetail(id: id),
  adminBuilder: (_) => const TeacherAdmin(),
  accountStatsBuilder: (_) => const TeacherAccountStats(),
  notificationsLoader: teacherNotifications,
  configure: (services) async {
    services.clearPrivateMedia = ClassroomPending.clearAll;
  },
);
