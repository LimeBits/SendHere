import 'package:flutter_test/flutter_test.dart';
import 'package:send_here/src/send_here_app.dart';

void main() {
  testWidgets('shows SendHere desktop UI without a title bar label',
      (tester) async {
    await tester.pumpWidget(const SendHereApp());
    expect(find.text('SendHere · 传到这'), findsNothing);
    expect(find.byType(SendHereHome), findsOneWidget);
  });
}
