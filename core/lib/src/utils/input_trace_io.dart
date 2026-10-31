import 'dart:io';

const _supportDir = String.fromEnvironment('ALERA_E2E_SUPPORT_DIR');

IOSink? _sink;

/// Appends one input-path line when an isolated E2E build provides a support
/// directory. Empty in every other build. The sink stays open so a flush
/// does not stall the key that is being diagnosed.
void traceTerminalInput(String message) {
  if (_supportDir.isEmpty) {
    return;
  }
  try {
    final sink = _sink ??= File(
      '$_supportDir/input_trace.log',
    ).openWrite(mode: FileMode.writeOnlyAppend);
    sink.writeln('${DateTime.now().toIso8601String()} $message');
  } catch (_) {}
}
