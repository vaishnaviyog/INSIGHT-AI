import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vaishnavi/main.dart';

void main() {
  testWidgets('App load smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const VaishnaviApp(showOnboarding: false));

    // Verify that our app starts.
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
