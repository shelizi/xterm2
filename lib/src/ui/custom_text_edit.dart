import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'input_trace.dart' if (dart.library.io) 'input_trace_io.dart';

/// Marks a subtree whose [CustomTextEdit] must open its platform input
/// connection at mount time instead of waiting for real focus.
///
/// A detached native window is created hidden and only becomes visible after
/// the host calls `completeShow`. The hidden view never receives focus, so the
/// usual focus-driven attach would not run at all, and the platform would
/// silently drop every keystroke queued between window creation and the first
/// focus. Attaching eagerly while the window is hidden lets the host order
/// `setClient` before `show`, after which no keystroke can outrun the client.
class EarlyInputAttachScope extends InheritedWidget {
  const EarlyInputAttachScope({super.key, required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<EarlyInputAttachScope>() !=
      null;

  @override
  bool updateShouldNotify(EarlyInputAttachScope oldWidget) => false;
}

class CustomTextEdit extends StatefulWidget {
  CustomTextEdit({
    super.key,
    required this.child,
    required this.onInsert,
    required this.onDelete,
    required this.onComposing,
    required this.onAction,
    required this.onKeyEvent,
    required this.focusNode,
    this.autofocus = false,
    this.readOnly = false,
    // this.initEditingState = TextEditingValue.empty,
    this.inputType = TextInputType.text,
    this.inputAction = TextInputAction.newline,
    this.keyboardAppearance = Brightness.light,
    this.deleteDetection = false,
    this.viewId,
  });

  final Widget child;

  final void Function(String) onInsert;

  final void Function() onDelete;

  final void Function(String?) onComposing;

  final void Function(TextInputAction) onAction;

  final KeyEventResult Function(FocusNode, KeyEvent) onKeyEvent;

  final FocusNode focusNode;

  final bool autofocus;

  final bool readOnly;

  final TextInputType inputType;

  final TextInputAction inputAction;

  final Brightness keyboardAppearance;

  final bool deleteDetection;

  final int? viewId;

  @override
  CustomTextEditState createState() => CustomTextEditState();
}

class CustomTextEditState extends State<CustomTextEdit> with TextInputClient {
  TextInputConnection? _connection;
  int? _attachedViewId;

  /// The platform keeps a single input client per view. A second [CustomTextEdit]
  /// in the same view that attaches (early-attach scopes do this before focus)
  /// silently replaces the current client while the first connection's local
  /// `attached` flag stays true. Tracking the owner lets a focused field reclaim
  /// the client instead of trusting a stale flag.
  static final Map<int, CustomTextEditState> _attachedOwners = {};
  Timer? _suppressEnterTimer;

  /// While a post-commit guard is armed, Enter-shaped input is the echo of
  /// the key that closed the IME composer, not a deliberate submit.
  static const _enterReplayGuard = Duration(milliseconds: 50);

  @override
  void initState() {
    widget.focusNode.addListener(_onFocusChange);
    super.initState();
  }

  @override
  void didUpdateWidget(CustomTextEdit oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.focusNode != oldWidget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChange);
      widget.focusNode.addListener(_onFocusChange);
    }

    final viewChanged = widget.viewId != oldWidget.viewId;
    if (!_shouldCreateInputConnection) {
      _closeInputConnectionIfNeeded();
    } else if (viewChanged && hasInputConnection) {
      _closeInputConnectionIfNeeded();
      _openInputConnection();
    } else if (oldWidget.readOnly && widget.focusNode.hasFocus) {
      _openInputConnection();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final viewId = _viewIdForConnection();
    if (hasInputConnection && viewId != _attachedViewId) {
      _closeInputConnectionIfNeeded();
      _openInputConnection();
      return;
    }
    // A subtree marked eager must attach before the OS window is shown:
    // a hidden detached view never receives focus, so the focus-driven path
    // below would leave the platform client unset and the window would open
    // with every early keystroke dropped at the embedder.
    if (EarlyInputAttachScope.of(context) &&
        _shouldCreateInputConnection &&
        !hasInputConnection) {
      _openInputConnection();
      return;
    }
    // A FocusNode can already hold focus before this state mounts (autofocus
    // resolving, a node reparented between windows). The focus listener never
    // sees that transition, so the connection would stay closed until another
    // focus change and every keystroke in between would be dropped.
    _openOrCloseInputConnectionIfNeeded();
  }

  @override
  void dispose() {
    _suppressEnterTimer?.cancel();
    widget.focusNode.removeListener(_onFocusChange);
    _closeInputConnectionIfNeeded();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onKeyEvent: _onKeyEvent,
      child: widget.child,
    );
  }

  bool get hasInputConnection => _connection != null && _connection!.attached;

  void requestKeyboard() {
    if (widget.focusNode.hasFocus) {
      _openInputConnection();
    } else {
      widget.focusNode.requestFocus();
    }
  }

  void closeKeyboard() {
    if (hasInputConnection) {
      _connection?.close();
    }
  }

  void setEditingState(TextEditingValue value) {
    _currentEditingState = value;
    _connection?.setEditingState(value);
  }

  void setEditableRect(Rect rect, Rect caretRect) {
    if (!hasInputConnection) {
      return;
    }

    _connection?.setEditableSizeAndTransform(
      rect.size,
      Matrix4.translationValues(rect.left, rect.top, 0),
    );

    _connection?.setCaretRect(caretRect);
  }

  void _onFocusChange() {
    traceTerminalInput(
      'focusChange has=${widget.focusNode.hasFocus} attached=$_attachedViewId',
    );
    _openOrCloseInputConnectionIfNeeded();
  }

  KeyEventResult _onKeyEvent(FocusNode focusNode, KeyEvent event) {
    traceTerminalInput(
      'client ${event.runtimeType} label=${event.logicalKey.keyLabel} char=${event.character} composing=${!_currentEditingState.composing.isCollapsed} view=$_attachedViewId',
    );
    if (_currentEditingState.composing.isCollapsed) {
      if (_suppressesReplayEnter(event)) {
        return KeyEventResult.skipRemainingHandlers;
      }
      // On macOS raw printable keys precede the IME's committed text. Sending
      // both to the PTY leaks Zhuyin phonetic keys or duplicates Latin input.
      if (_usesMacTextInputForKey(event)) {
        return KeyEventResult.skipRemainingHandlers;
      }
      return widget.onKeyEvent(focusNode, event);
    }

    // The IME owns every key while composition is open. Enter only selects a
    // candidate or closes the composer; forwarding it would submit a command
    // the user is still editing.
    return KeyEventResult.skipRemainingHandlers;
  }

  bool _usesMacTextInputForKey(KeyEvent event) {
    if (defaultTargetPlatform != TargetPlatform.macOS || !hasInputConnection) {
      return false;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return false;
    }
    if (event.logicalKey == LogicalKeyboardKey.space) {
      return true;
    }
    final label = event.logicalKey.keyLabel;
    return label.runes.length == 1 && label.runes.first >= 0x20;
  }

  void _openOrCloseInputConnectionIfNeeded() {
    if (widget.focusNode.hasFocus && widget.focusNode.consumeKeyboardToken()) {
      _openInputConnection();
    } else if (!widget.focusNode.hasFocus) {
      _closeInputConnectionIfNeeded();
    }
  }

  bool get _shouldCreateInputConnection => kIsWeb || !widget.readOnly;

  int? _viewIdForConnection() {
    return widget.viewId ?? View.maybeOf(context)?.viewId;
  }

  void _openInputConnection() {
    if (!_shouldCreateInputConnection) {
      return;
    }
    traceTerminalInput(
      'open requestedView=${widget.viewId} resolved=${_viewIdForConnection()} attached=$_attachedViewId has=$hasInputConnection',
    );

    if (hasInputConnection) {
      final viewId = _viewIdForConnection();
      if (_attachedOwners[viewId] == this) {
        _connection!.show();
      } else {
        // Another client in this view attached after us. The platform no
        // longer routes input here; close and re-attach to reclaim it.
        _closeInputConnectionIfNeeded();
        _openInputConnection();
      }
    } else {
      final viewId = _viewIdForConnection();
      if (viewId == null) {
        throw Exception('Cannot open input connection without a valid viewId.');
      }
      final config = TextInputConfiguration(
        viewId: viewId,
        inputType: widget.inputType,
        inputAction: widget.inputAction,
        keyboardAppearance: widget.keyboardAppearance,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
      );

      _connection = TextInput.attach(this, config);

      _connection!.show();

      // setEditableRect(Rect.zero, Rect.zero);

      _connection!.setEditingState(_initEditingState);
      _attachedViewId = viewId;
      _attachedOwners[viewId] = this;
    }
  }

  void _closeInputConnectionIfNeeded() {
    traceTerminalInput(
      'close attached=$_attachedViewId has=$hasInputConnection editing="${_currentEditingState.text}"',
    );
    _suppressEnterTimer?.cancel();
    _suppressEnterTimer = null;
    if (_connection != null && _connection!.attached) {
      final viewId = _attachedViewId;
      if (viewId != null && _attachedOwners[viewId] == this) {
        _connection!.close();
      } else {
        // A newer client already owns this view's platform channel (e.g. a
        // detached tab switch mounts its replacement before this state is
        // disposed). clearClient would detach *that* client, so only the
        // recorded owner may send it; here we just drop the stale handle.
        _connection = null;
      }
    }
    if (_attachedOwners[_attachedViewId] == this) {
      _attachedOwners.remove(_attachedViewId);
    }
    _attachedViewId = null;
  }

  TextEditingValue get _initEditingState => widget.deleteDetection
      ? const TextEditingValue(
          text: '  ',
          selection: TextSelection.collapsed(offset: 2),
        )
      : const TextEditingValue(
          text: '',
          selection: TextSelection.collapsed(offset: 0),
        );

  late var _currentEditingState = _initEditingState.copyWith();

  @override
  TextEditingValue? get currentTextEditingValue {
    return _currentEditingState;
  }

  @override
  AutofillScope? get currentAutofillScope {
    return null;
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    final previousText = _currentEditingState.text;
    final wasComposing = !_currentEditingState.composing.isCollapsed;
    _currentEditingState = value;
    traceTerminalInput(
      'edit text="${value.text}" sel=${value.selection.start}:${value.selection.end} composing=${value.composing.start}:${value.composing.end}',
    );

    // Get input after composing is done
    if (!_currentEditingState.composing.isCollapsed) {
      final text = _currentEditingState.text;
      final composingText = _currentEditingState.composing.textInside(text);
      widget.onComposing(composingText);
      return;
    }

    widget.onComposing(null);

    var insertedText = '';
    final newText = _currentEditingState.text;
    if (newText.length < _initEditingState.text.length) {
      widget.onDelete();
    } else if (newText != previousText &&
        previousText.length >= _initEditingState.text.length &&
        newText.startsWith(previousText)) {
      // The platform still holds text we already consumed because the reset
      // pushed below had not landed when this update was produced. Emit only
      // the genuinely new suffix instead of replaying the whole buffer.
      insertedText = newText.substring(previousText.length);
      widget.onInsert(insertedText);
    } else {
      // A fresh value after the platform reset landed, an identical retype of
      // the previous text, an outright replacement, or a buffer that shrank
      // to a prefix of the stale consumed text (the reset landed and this is
      // new input, not a reset echo to swallow).
      insertedText = newText.substring(_initEditingState.text.length);
      widget.onInsert(insertedText);
    }

    // Reset editing state if composing is done
    if (_currentEditingState.composing.isCollapsed &&
        _currentEditingState.text != _initEditingState.text) {
      _connection!.setEditingState(_initEditingState);
    }

    // Windows can echo the Enter that closed the composer as a key event or
    // input action right after the commit lands. It belongs to the IME, so a
    // submit-shaped event within this window is swallowed; the next
    // deliberate Enter reaches the terminal normally.
    if (wasComposing && defaultTargetPlatform == TargetPlatform.windows) {
      _armEnterReplayGuard();
    }
  }

  @override
  void performAction(TextInputAction action) {
    // print('performAction $action');
    if (action == TextInputAction.done || action == TextInputAction.newline) {
      // A submit-shaped action that arrives while the IME owns the text is
      // the candidate/commit key, not a terminal submission. macOS drops it
      // unconditionally because Return also arrives as a hardware key.
      if (defaultTargetPlatform == TargetPlatform.macOS ||
          !_currentEditingState.composing.isCollapsed) {
        return;
      }
      if (_suppressesReplayEnter(const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.enter,
        logicalKey: LogicalKeyboardKey.enter,
        timeStamp: Duration.zero,
      ))) {
        return;
      }
    }
    widget.onAction(action);
  }

  void _armEnterReplayGuard() {
    _suppressEnterTimer?.cancel();
    _suppressEnterTimer = Timer(_enterReplayGuard, () {
      _suppressEnterTimer = null;
    });
  }

  bool _suppressesReplayEnter(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.enter) {
      return false;
    }
    return _suppressEnterTimer != null;
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {
    // print('updateFloatingCursor $point');
  }

  @override
  void showAutocorrectionPromptRect(int start, int end) {
    // print('showAutocorrectionPromptRect');
  }

  @override
  void connectionClosed() {
    // print('connectionClosed');
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {
    // print('performPrivateCommand $action');
  }

  @override
  void insertTextPlaceholder(Size size) {
    // print('insertTextPlaceholder');
  }

  @override
  void removeTextPlaceholder() {
    // print('removeTextPlaceholder');
  }

  @override
  void showToolbar() {
    // print('showToolbar');
  }
}
