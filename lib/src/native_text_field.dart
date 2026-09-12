import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Text input backed by a real macOS `NSTextView`.
///
/// Flutter renders its own text field rather than a native control, so macOS
/// dictation and third-party speech input methods have no native responder to
/// insert into. Hosting an `NSTextView` gives the standard macOS text input
/// path: input methods, dictation, marked text and paste all behave normally.
class NativeComposeItem {
  const NativeComposeItem.text(this.text)
      : filePath = null,
        fileName = null;
  const NativeComposeItem.file(this.filePath, this.fileName) : text = null;

  final String? text;
  final String? filePath;
  final String? fileName;

  Map<String, String> toMap() => text != null
      ? {'type': 'text', 'text': text!}
      : {'type': 'file', 'path': filePath!, 'name': fileName!};
}

class NativeTextField extends StatefulWidget {
  const NativeTextField({
    super.key,
    required this.onChanged,
    required this.onSubmitted,
    required this.onFilesDropped,
    required this.onComposeChanged,
    required this.onContentHeightChanged,
    required this.initialText,
    required this.composeItems,
    this.height = 96,
  });

  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final ValueChanged<List<String>> onFilesDropped;
  final ValueChanged<List<NativeComposeItem>> onComposeChanged;
  final ValueChanged<double> onContentHeightChanged;
  final String initialText;
  final List<NativeComposeItem> composeItems;
  final double height;

  static const viewType = 'sendhere/native_text_field';

  @override
  State<NativeTextField> createState() => NativeTextFieldState();
}

class NativeTextFieldState extends State<NativeTextField> {
  MethodChannel? _channel;
  final _mobileController = TextEditingController();
  final _mobileFocusNode = FocusNode();
  bool _skipNextComposeUpdate = false;

  @override
  void initState() {
    super.initState();
    _mobileController.text = widget.initialText;
  }

  Future<void> clear() async {
    developer.log('Clearing native text field', name: 'SendHere.Input');
    _mobileController.clear();
    await _channel?.invokeMethod<void>('setText', '');
  }

  Future<void> focus() async {
    _mobileFocusNode.requestFocus();
    await _channel?.invokeMethod<void>('focus');
  }

  Future<void> unfocus() async {
    _mobileFocusNode.unfocus();
    await _channel?.invokeMethod<void>('unfocus');
  }

  Future<void> _setCompose() =>
      _channel?.invokeMethod<void>(
        'setCompose',
        {
          'items': widget.composeItems.map((item) => item.toMap()).toList(),
          'draft': widget.initialText,
        },
      ) ??
      Future<void>.value();

  void _attach(int id) {
    final channel = MethodChannel('sendhere/native_text_field/$id');
    channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'textChanged':
          widget.onChanged(call.arguments as String? ?? '');
        case 'submit':
          widget.onSubmitted(call.arguments as String? ?? '');
        case 'filesDropped':
          final paths = (call.arguments as List<dynamic>? ?? const [])
              .whereType<String>()
              .toList();
          developer.log('Received ${paths.length} dropped file(s)',
              name: 'SendHere.Input');
          widget.onFilesDropped(paths);
        case 'contentHeightChanged':
          final height = (call.arguments as num?)?.toDouble();
          if (height != null) widget.onContentHeightChanged(height);
        case 'composeChanged':
          final values = (call.arguments as List<dynamic>? ?? const [])
              .whereType<Map<dynamic, dynamic>>();
          final items = <NativeComposeItem>[];
          for (final value in values) {
            final type = value['type'] as String?;
            if (type == 'text') {
              final text = value['text'] as String? ?? '';
              if (text.isNotEmpty) items.add(NativeComposeItem.text(text));
            } else if (type == 'file') {
              final filePath = value['path'] as String?;
              if (filePath != null) {
                items.add(NativeComposeItem.file(
                  filePath,
                  value['name'] as String? ?? filePath.split('/').last,
                ));
              }
            }
          }
          // Flutter stores this update for sending, but the native editor is
          // already the authoritative visual document. Do not rebuild it and
          // move the cursor to the end after every keystroke or deletion.
          _skipNextComposeUpdate = true;
          widget.onComposeChanged(items);
      }
      return null;
    });
    _channel = channel;
    developer.log(
        'Attached native text field with ${widget.initialText.length} characters',
        name: 'SendHere.Input');
    _setCompose();
  }

  @override
  void didUpdateWidget(covariant NativeTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final composeChanged = oldWidget.initialText != widget.initialText ||
        !_sameComposeItems(oldWidget.composeItems, widget.composeItems);
    if (_skipNextComposeUpdate) {
      _skipNextComposeUpdate = false;
      return;
    }
    if (composeChanged) {
      developer.log('Updating native text field', name: 'SendHere.Input');
      _mobileController.value = TextEditingValue(
        text: widget.initialText,
        selection: TextSelection.collapsed(offset: widget.initialText.length),
      );
      _setCompose();
    }
  }

  @override
  void dispose() {
    _mobileController.dispose();
    _mobileFocusNode.dispose();
    super.dispose();
  }

  bool _sameComposeItems(
    List<NativeComposeItem> left,
    List<NativeComposeItem> right,
  ) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index].text != right[index].text ||
          left[index].filePath != right[index].filePath ||
          left[index].fileName != right[index].fileName) {
        return false;
      }
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      return SizedBox(
        height: widget.height,
        child: AppKitView(
          viewType: NativeTextField.viewType,
          onPlatformViewCreated: _attach,
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        ),
      );
    }

    // iOS and Android do not host the macOS AppKit editor. Their standard
    // Flutter input path provides IME, paste and the on-screen keyboard.
    return SizedBox(
      height: widget.height,
      child: TextField(
        controller: _mobileController,
        focusNode: _mobileFocusNode,
        expands: true,
        maxLines: null,
        minLines: null,
        textAlignVertical: TextAlignVertical.top,
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
        decoration: const InputDecoration(
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          hintText: '输入消息',
        ),
        onChanged: widget.onChanged,
      ),
    );
  }
}
