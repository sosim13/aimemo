import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aimemo/main.dart';

void main() {
  testWidgets('App launches with home screen', (WidgetTester tester) async {
    await tester.pumpWidget(const AimemoApp());

    // Verify the app title is shown
    expect(find.text('Aimemo'), findsWidgets);

    // Verify key navigation elements exist
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });
}
