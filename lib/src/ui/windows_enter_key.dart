/// Platforms without a Win32 keyboard latch never report Enter as held.
bool windowsEnterKeyIsDown() => false;
