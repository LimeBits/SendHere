import 'package:flutter_test/flutter_test.dart';
import 'package:send_here/src/send_here_app.dart';

void main() {
  testWidgets('shows SendHere desktop UI', (tester) async {
    await tester.pumpWidget(const SendHereApp());
    expect(find.text('SendHere · 传到这'), findsOneWidget);
  });
}
