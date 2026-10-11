import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Selectable message text where a right-click selects the whole message
/// before showing the context menu. A range the user picked by dragging (or
/// double-clicking / keyboard) is kept if the right-click leaves it intact,
/// so "drag to select part, right-click → Copy" still works.
class MessageText extends StatefulWidget {
  const MessageText(this.text, {super.key});
  final String text;

  @override
  State<MessageText> createState() => MessageTextState();
}

class MessageTextState extends State<MessageText> {
  static const _userRangeCauses = {
    SelectionChangedCause.drag,
    SelectionChangedCause.doubleTap,
    SelectionChangedCause.keyboard,
  };

  TextSelection? _userRange;
  TextSelection? _rangeAtRightClick;
  bool _selectAllPending = false;

  void _onSelectionChanged(
      TextSelection selection, SelectionChangedCause? cause) {
    if (_userRangeCauses.contains(cause) && !selection.isCollapsed) {
      _userRange = selection;
    } else if (cause != null && cause != SelectionChangedCause.toolbar) {
      _userRange = null;
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    if (event.buttons & kSecondaryMouseButton == 0) return;
    _rangeAtRightClick = _userRange;
    _selectAllPending = true;
  }

  Widget _buildContextMenu(BuildContext context, EditableTextState state) {
    if (_selectAllPending) {
      _selectAllPending = false;
      final current = state.textEditingValue.selection;
      final keep = _rangeAtRightClick != null &&
          current.start == _rangeAtRightClick!.start &&
          current.end == _rangeAtRightClick!.end;
      final length = state.textEditingValue.text.length;
      if (!keep &&
          length > 0 &&
          !(current.start == 0 && current.end == length)) {
        // Selection can't change during build; apply it right after. The
        // toolbar rebuilds from the new selection so "Copy" copies everything.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!state.mounted) return;
          state.userUpdateTextEditingValue(
            state.textEditingValue.copyWith(
              selection: TextSelection(baseOffset: 0, extentOffset: length),
            ),
            SelectionChangedCause.toolbar,
          );
        });
      }
    }
    return AdaptiveTextSelectionToolbar.editableText(editableTextState: state);
  }

  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: _onPointerDown,
        child: SelectableText(
          widget.text,
          onSelectionChanged: _onSelectionChanged,
          contextMenuBuilder: _buildContextMenu,
        ),
      );
}
