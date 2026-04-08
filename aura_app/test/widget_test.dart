import 'package:flutter_test/flutter_test.dart';

import 'package:aura_app/main.dart';

void main() {
  testWidgets('AURA app builds', (WidgetTester tester) async {
    await tester.pumpWidget(const AuraApp());
    expect(find.text('BUSCAR OBJETO'), findsOneWidget);
  });
}
