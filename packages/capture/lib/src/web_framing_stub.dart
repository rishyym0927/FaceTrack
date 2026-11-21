import 'framing.dart';

Future<bool> startWebFraming() async => false;
void stopWebFraming() {}
FramingReading readWebFraming() => const FramingReading();
void guardWebUnload(bool on) {}
void Function() watchWebDevices(void Function() onChange) => () {};
