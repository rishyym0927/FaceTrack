import 'package:facetrack_core/facetrack_core.dart';

import 'teacher_classes.dart';
import 'teacher_sessions.dart';

void main() => launchProduct(
  AppConfig.environment(AppRole.teacher),
  classesBuilder: (_) => const TeacherClasses(),
  sessionBuilder: (_, id) => TeacherSessionDetail(id: id),
  detailBuilder: (_, id) => TeacherClassDetail(id: id),
);
