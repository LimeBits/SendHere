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
class NativeTextField extends StatefulWidget {
  const NativeTextField({
    super.key,
    required this.onChanged,
    required this.onSubmitted,
    required this.initialText,
    this.height = 96,
  });

  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final String initialText;
  final double height;

  static const viewType = 'sendhere/native_text_field';

  @override
  State<NativeTextField> createState() => NativeTextFieldState();
}

class NativeTextFieldState extends State<NativeTextField> {
  MethodChannel? _channel;

  Future<void> clear() async {
    developer.log('Clearing native text field', name: 'SendHere.Input');
    await _channel?.invokeMethod<void>('setText', '');
  }

  void _attach(int id) {
    final channel = MethodChannel('sendhere/native_text_field/$id');
    channel.setMethodCallHandler((call) async {
      final value = call.arguments as String? ?? '';
      switch (call.method) {
        case 'textChanged':
          widget.onChanged(value);
        case 'submit':
          widget.onSubmitted(value);
      }
      return null;
    });
    _channel = channel;
    developer.log(
        'Attached native text field with ${widget.initialText.length} characters',
        name: 'SendHere.Input');
    channel.invokeMethod<void>('setText', widget.initialText);
  }

  @override
  void didUpdateWidget(covariant NativeTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialText != widget.initialText) {
      developer.log(
          'Updating native text field: ${oldWidget.initialText.length} → ${widget.initialText.length} characters',
          name: 'SendHere.Input');
      _channel?.invokeMethod<void>('setText', widget.initialText);
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        height: widget.height,
        child: AppKitView(
          viewType: NativeTextField.viewType,
          onPlatformViewCreated: _attach,
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        ),
      );
}
