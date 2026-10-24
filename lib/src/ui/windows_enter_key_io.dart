import 'dart:ffi';
import 'dart:io';

typedef _GetAsyncKeyStateNative = Int16 Function(Int32 vKey);
typedef _GetAsyncKeyStateDart = int Function(int vKey);

_GetAsyncKeyStateDart? _getAsyncKeyState;

/// Whether VK_RETURN is down right now.
///
/// Windows IMEs often consume the Enter key that commits composition, so the
/// Flutter key event never arrives. The kernel key state still does.
bool windowsEnterKeyIsDown() {
  if (!Platform.isWindows) {
    return false;
  }
  try {
    final probe = _getAsyncKeyState ??= DynamicLibrary.open(
      'user32.dll',
    ).lookupFunction<_GetAsyncKeyStateNative, _GetAsyncKeyStateDart>(
      'GetAsyncKeyState',
    );
    // The high bit is set while the key is down. VK_RETURN covers the main
    // Enter key and the numpad Enter key.
    return (probe(0x0D) & 0x8000) != 0;
  } on Object {
    return false;
  }
}
