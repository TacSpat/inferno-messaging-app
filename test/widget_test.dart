import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:inferno/app.dart';

void main() {
  testWidgets('App boots without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: InfernoApp()),
    );
    // Just verify the app builds and shows the loading indicator
    // (LoginScreen does async auth check which requires platform channels)
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
