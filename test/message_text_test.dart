import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:send_here/src/message_text.dart';

const _text = 'hello world from SendHere';

Future<void> _pump(WidgetTester tester) => tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: MessageText(_text))),
      ),
    );

TextSelection _selection(WidgetTester tester) => tester
    .state<EditableTextState>(find.byType(EditableText))
    .textEditingValue
    .selection;

Future<void> _rightClick(WidgetTester tester, Offset at) async {
  final gesture = await tester.startGesture(at,
      kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('right-click selects the whole message', (tester) async {
    await _pump(tester);
    final box = tester.getRect(find.byType(EditableText));
    await _rightClick(tester, box.centerLeft + const Offset(4, 0));

    final selection = _selection(tester);
    expect(selection.start, 0);
    expect(selection.end, _text.length);
  });

  testWidgets('right-click keeps a drag selection', (tester) async {
    await _pump(tester);
    final box = tester.getRect(find.byType(EditableText));
    final gesture = await tester.startGesture(
        box.centerLeft + const Offset(1, 0),
        kind: PointerDeviceKind.mouse);
    await tester.pump();
    await gesture.moveTo(box.center);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    final dragged = _selection(tester);
    expect(dragged.isCollapsed, isFalse);
    expect(dragged.end, lessThan(_text.length));

    await _rightClick(
        tester, box.centerLeft + Offset((box.center.dx - box.left) / 2, 0));

    final after = _selection(tester);
    expect(after.start, dragged.start);
    expect(after.end, dragged.end);
  });
}
