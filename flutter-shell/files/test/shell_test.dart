import 'package:client_app/src/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the shell starts on Records and offers Settings', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ClientApp());
    await tester.pumpAndSettle();

    expect(find.text('Records'), findsWidgets);
    expect(find.text('Settings'), findsWidgets);
  });

  testWidgets('a fresh application shows no invented records', (
    WidgetTester tester,
  ) async {
    // The point of the empty state, asserted so that adding demo data to make
    // a screenshot look better fails here first.
    await tester.pumpWidget(const ClientApp());
    await tester.pumpAndSettle();

    expect(find.text('Nothing here yet'), findsOneWidget);
  });

  testWidgets('an unconfigured platform address says so', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ClientApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();

    expect(find.textContaining('Not set'), findsOneWidget);
  });
}
