import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/map_screen.dart';
import '../lib/route_session.dart';

// Replaces Flutter's starter counter test, which no longer matches this app.
// Tests the real edit dialog without requiring a native Google Map.
void main() {
  testWidgets('Route editor validates a name and returns color and style', (
    tester,
  ) async {
    RouteDetails? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<RouteDetails>(
                  context: context,
                  builder: (_) => const RouteDetailsDialog(
                    title: 'Edit route',
                    initialName: 'Morning walk',
                    initialColor: 0xff1565c0,
                    initialPattern: RoutePattern.solid,
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('Enter a route name.'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), 'Evening walk');
    await tester.tap(find.byTooltip('Red'));
    await tester.tap(find.text('dashed'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result?.name, 'Evening walk');
    expect(result?.color, 0xffc62828);
    expect(result?.pattern, RoutePattern.dashed);
  });
}
