import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/route_session.dart';
import '../lib/route_store.dart';
import '../lib/tracker_controller.dart';

RoutePoint point(double lng, [int seconds = 0]) => RoutePoint(
  0,
  lng,
  DateTime.utc(2026, 1, 1).add(Duration(seconds: seconds)),
  5,
);
RouteSession route(String id, {RouteStatus status = RouteStatus.finished}) =>
    RouteSession(
      id: id,
      name: id,
      colorValue: 0xff1565c0,
      createdAt: DateTime.utc(2026),
      status: status,
    );

class MemoryRepository implements SessionRepository {
  List<RouteSession> stored = [];
  bool failLoad = false;
  bool failSave = false;
  int writes = 0;

  @override
  Future<List<RouteSession>> load() async {
    if (failLoad) throw const FormatException('Damaged file');
    return stored.map((r) => RouteSession.fromJson(r.toJson())).toList();
  }

  @override
  Future<void> save(List<RouteSession> routes) async {
    if (failSave) throw const FileSystemException('Disk full');
    writes++;
    stored = routes.map((r) => RouteSession.fromJson(r.toJson())).toList();
  }
}

Future<void> settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test('JSON round trip preserves sessions, colors, styles and segments', () {
    final session = route('walk')..pattern = RoutePattern.dotted;
    session.addPoint(point(0), newSegment: true);
    session.addPoint(point(0.001, 10), newSegment: false);
    session.addPoint(point(10, 100), newSegment: true);
    final restored = RouteSession.fromJson(
      jsonDecode(jsonEncode(session.toJson())) as Map<String, dynamic>,
    );
    expect(restored.pointCount, 3);
    expect(restored.segments.length, 2);
    expect(restored.pattern, RoutePattern.dotted);
    expect(restored.colorValue, session.colorValue);
    expect(restored.distanceMeters, closeTo(111.19, 0.2));
    expect(restored.sampledDuration, const Duration(seconds: 10));
  });

  test('Invalid coordinates are rejected instead of silently clamped', () {
    expect(
      () => RoutePoint.fromJson({
        'lat': 200,
        'lng': 0,
        'time': '2026-01-01T00:00:00Z',
        'accuracy': 5,
      }),
      throwsFormatException,
    );
  });

  test(
    'File writes are ordered and snapshots cannot resurrect deleted routes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'route_journal_test_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final repository = JsonSessionRepository(
        directoryProvider: () async => directory,
      );
      final routes = [route('A'), route('B')];
      final first = repository.save(routes);
      routes.removeAt(0);
      routes.first.colorValue = 0xffc62828;
      final second = repository.save(routes);
      await Future.wait([first, second]);
      final restored = await repository.load();
      expect(restored.map((r) => r.id), ['B']);
      expect(restored.single.colorValue, 0xffc62828);
      await repository.save([]);
      expect(await repository.load(), isEmpty);
    },
  );

  test('Malformed saved data is not treated as an empty route list', () async {
    final directory = await Directory.systemTemp.createTemp(
      'route_journal_bad_',
    );
    addTearDown(() => directory.delete(recursive: true));
    await File('${directory.path}/route_sessions_v2.json')
        .writeAsString('{broken');
    final repository = JsonSessionRepository(
      directoryProvider: () async => directory,
    );
    await expectLater(repository.load(), throwsFormatException);
  });

  test(
    'A recording session restores as paused and does not collect GPS',
    () async {
      final repository = MemoryRepository()
        ..stored = [route('unfinished', status: RouteStatus.recording)];
      var reads = 0;
      final tracker = TrackerController(
        repository: repository,
        locationReader: (_) async {
          reads++;
          return point(0);
        },
      );
      addTearDown(tracker.dispose);
      await tracker.initialize();
      expect(tracker.active?.status, RouteStatus.paused);
      expect(reads, 0);
    },
  );

  test(
    'Pause/resume creates a gap; finish allows a separate new route',
    () async {
      final repository = MemoryRepository();
      var longitude = 0.0;
      final tracker = TrackerController(
        repository: repository,
        locationReader: (_) async => point(longitude),
      );
      addTearDown(tracker.dispose);
      await tracker.initialize();
      tracker.start('A', 0xff1565c0, RoutePattern.solid);
      await settle();
      longitude = 0.001;
      await tracker.refreshLocation();
      tracker.pause();
      longitude = 10;
      tracker.resume();
      await settle();
      expect(tracker.active!.segments.length, 2);
      expect(tracker.active!.distanceMeters, lessThan(120));
      tracker.finish();
      tracker.start('B', 0xffc62828, RoutePattern.dashed);
      await settle();
      expect(tracker.routes.length, 2);
      expect(tracker.routes.last.status, RouteStatus.finished);
      expect(tracker.active!.name, 'B');
    },
  );

  test('Deleting a recording route rejects its in-flight GPS result', () async {
    final fix = Completer<RoutePoint>();
    final tracker = TrackerController(
      repository: MemoryRepository(),
      locationReader: (_) => fix.future,
    );
    addTearDown(tracker.dispose);
    await tracker.initialize();
    tracker.start('A', 0xff1565c0, RoutePattern.solid);
    tracker.deleteRoute(tracker.activeId!);
    fix.complete(point(1));
    await settle();
    expect(tracker.routes, isEmpty);
    expect(tracker.currentPoint, isNull);
    expect(tracker.recording, isFalse);
  });

  test('Backgrounding pauses and discards a stale reading', () async {
    final fix = Completer<RoutePoint>();
    final tracker = TrackerController(
      repository: MemoryRepository(),
      locationReader: (_) => fix.future,
    );
    addTearDown(tracker.dispose);
    await tracker.initialize();
    tracker.start('A', 0xff1565c0, RoutePattern.solid);
    tracker.setForeground(false, pauseRecording: true);
    fix.complete(point(1));
    await settle();
    tracker.setForeground(true);
    expect(tracker.active!.status, RouteStatus.paused);
    expect(tracker.active!.pointCount, 0);
  });

  test(
    'Compare visibility is independent of route data and recording',
    () async {
      final repository = MemoryRepository()..stored = [route('A'), route('B')];
      final tracker = TrackerController(
        repository: repository,
        locationReader: (_) async => point(0),
      );
      addTearDown(tracker.dispose);
      await tracker.initialize();
      expect(tracker.displayedRoutes.map((r) => r.id), ['A']);
      tracker.setFocusOnly(false);
      expect(tracker.displayedRoutes.length, 2);
      tracker.toggleVisibility('A');
      expect(tracker.displayedRoutes.map((r) => r.id), ['B']);
      tracker.select('A');
      expect(tracker.displayedRoutes.length, 2);
      tracker.setFocusOnly(true);
      expect(tracker.displayedRoutes.map((r) => r.id), ['A']);
      expect(tracker.routes.length, 2);
    },
  );

  test('Load failure blocks recording and preserves stored data', () async {
    final repository = MemoryRepository()..failLoad = true;
    final tracker = TrackerController(
      repository: repository,
      locationReader: (_) async => point(0),
    );
    addTearDown(tracker.dispose);
    await tracker.initialize();
    tracker.start('A', 0xff1565c0, RoutePattern.solid);
    expect(tracker.ready, isFalse);
    expect(tracker.routes, isEmpty);
    expect(repository.writes, 0);
  });

  test('Save failure is visible and retry preserves edits', () async {
    final repository = MemoryRepository()..stored = [route('A')];
    final tracker = TrackerController(
      repository: repository,
      locationReader: (_) async => point(0),
    );
    addTearDown(tracker.dispose);
    await tracker.initialize();
    repository.failSave = true;
    tracker.updateRoute('A', 'Renamed', 0xffc62828, RoutePattern.dotted);
    await settle();
    expect(tracker.saveError, isNotNull);
    repository.failSave = false;
    await tracker.save();
    expect(tracker.saveError, isNull);
    expect(repository.stored.single.name, 'Renamed');
  });
}
