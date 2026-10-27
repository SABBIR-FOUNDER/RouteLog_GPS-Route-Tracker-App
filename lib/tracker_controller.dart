import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'route_session.dart';
import 'route_store.dart';

enum LocationAction { none, deviceSettings, appSettings }

class LocationProblem implements Exception {
  const LocationProblem(this.message, [this.action = LocationAction.none]);
  final String message;
  final LocationAction action;
}

typedef LocationReader = Future<RoutePoint> Function(bool askPermission);

Future<RoutePoint> readDeviceLocation(bool askPermission) async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw const LocationProblem(
      'Turn on device location.',
      LocationAction.deviceSettings,
    );
  }
  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied && askPermission) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.deniedForever) {
    throw const LocationProblem(
      'Allow location in app settings.',
      LocationAction.appSettings,
    );
  }
  if (permission != LocationPermission.always &&
      permission != LocationPermission.whileInUse) {
    throw const LocationProblem(
      'Location permission is needed. Tap Find me or Resume.',
    );
  }
  final position = await Geolocator.getCurrentPosition(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      timeLimit: Duration(seconds: 20),
    ),
  );
  return RoutePoint(
    position.latitude,
    position.longitude,
    position.timestamp,
    position.accuracy.isFinite ? max(0.0, position.accuracy) : 0.0,
  );
}

class TrackerController extends ChangeNotifier {
  TrackerController({
    SessionRepository? repository,
    LocationReader? locationReader,
    this.interval = const Duration(seconds: 10),
  }) : _repository = repository ?? JsonSessionRepository(),
       _readLocation = locationReader ?? readDeviceLocation;

  final SessionRepository _repository;
  final LocationReader _readLocation;
  final Duration interval;
  final List<RouteSession> routes = [];
  final Set<String> hiddenIds = {};
  Timer? _timer;
  bool _disposed = false;
  bool _foreground = true;
  bool _newSegment = true;
  int _generation = 0;
  int _saveRevision = 0;
  int _pendingSaves = 0;

  bool loading = false;
  bool ready = false;
  bool fetching = false;
  bool focusOnly = true;
  bool followMe = false;
  String? selectedId;
  String? activeId;
  RoutePoint? currentPoint;
  String message = 'Loading saved routes...';
  String? loadError;
  String? saveError;
  LocationAction locationAction = LocationAction.none;

  bool get saving => _pendingSaves > 0;
  RouteSession? byId(String? id) {
    for (final route in routes) {
      if (route.id == id) return route;
    }
    return null;
  }

  RouteSession? get selected => byId(selectedId);
  RouteSession? get active => byId(activeId);
  bool get recording => active?.status == RouteStatus.recording;
  List<RouteSession> get displayedRoutes => routes
      .where(
        (route) =>
            !hiddenIds.contains(route.id) &&
            (!focusOnly || route.id == selectedId),
      )
      .toList();

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    if (loading || ready || _disposed) return;
    loading = true;
    loadError = null;
    _emit();
    try {
      final restored = await _repository.load();
      if (_disposed) return;
      routes.addAll(restored);
      var changed = false;
      for (final route in routes) {
        if (route.status == RouteStatus.recording) {
          route.status = RouteStatus.paused;
          changed = true;
        }
        if (route.status == RouteStatus.paused) activeId = route.id;
      }
      selectedId = activeId ?? (routes.isEmpty ? null : routes.first.id);
      ready = true;
      message = active == null
          ? 'Ready. Start a new route.'
          : 'Route restored and paused. Tap Resume.';
      _timer = Timer.periodic(interval, (_) {
        if (_foreground && recording) unawaited(refreshLocation());
      });
      if (changed) unawaited(save());
    } catch (error) {
      loadError = 'Could not read saved routes. Existing data has not been overwritten.';
      debugPrint('Route load failed: $error');
    } finally {
      loading = false;
      _emit();
    }
  }

  Future<void> save() async {
    if (!ready || _disposed) return;
    final revision = ++_saveRevision;
    _pendingSaves++;
    _emit();
    try {
      await _repository.save(routes);
      if (revision == _saveRevision) saveError = null;
    } catch (error) {
      if (revision == _saveRevision) {
        saveError =
            'Changes are not saved. Keep the app open and tap Retry save.';
      }
      debugPrint('Route save failed: $error');
    } finally {
      _pendingSaves--;
      _emit();
    }
  }

  void start(String name, int color, RoutePattern pattern) {
    if (!ready || active != null || _disposed || !_foreground) return;
    final now = DateTime.now();
    final route = RouteSession(
      id: '${now.microsecondsSinceEpoch}-${Random().nextInt(1 << 30)}',
      name: name.trim().isEmpty ? 'Route ${routes.length + 1}' : name.trim(),
      colorValue: color,
      pattern: pattern,
      createdAt: now,
    );
    _generation++;
    _newSegment = true;
    routes.insert(0, route);
    selectedId = activeId = route.id;
    focusOnly = true;
    message = 'Recording ${route.name}';
    _emit();
    unawaited(save());
    unawaited(refreshLocation(askPermission: true));
  }

  void pause({String? reason}) {
    final route = active;
    if (route == null || route.status != RouteStatus.recording) return;
    _generation++;
    _newSegment = true;
    route.status = RouteStatus.paused;
    message = reason ?? '${route.name} paused.';
    _emit();
    unawaited(save());
  }

  void resume() {
    final route = active;
    if (route == null || route.status != RouteStatus.paused || !_foreground)
      return;
    _generation++;
    _newSegment = true;
    route.status = RouteStatus.recording;
    selectedId = route.id;
    hiddenIds.remove(route.id);
    message = 'Recording ${route.name}';
    _emit();
    unawaited(save());
    unawaited(refreshLocation(askPermission: true));
  }

  void finish() {
    final route = active;
    if (route == null) return;
    _generation++;
    route.status = RouteStatus.finished;
    activeId = null;
    _newSegment = true;
    message = '${route.name} finished.';
    _emit();
    unawaited(save());
  }

  void updateRoute(String id, String name, int color, RoutePattern pattern) {
    final route = byId(id);
    if (route == null) return;
    route.name = name.trim().isEmpty ? route.name : name.trim();
    route.colorValue = color;
    route.pattern = pattern;
    _emit();
    unawaited(save());
  }

  void deleteRoute(String id) {
    if (activeId == id) {
      _generation++;
      activeId = null;
      _newSegment = true;
    }
    routes.removeWhere((route) => route.id == id);
    hiddenIds.remove(id);
    if (selectedId == id) {
      selectedId = activeId ?? (routes.isEmpty ? null : routes.first.id);
      hiddenIds.remove(selectedId);
    }
    message = 'Route deleted.';
    _emit();
    unawaited(save());
  }

  void select(String id) {
    if (byId(id) == null) return;
    selectedId = id;
    hiddenIds.remove(id);
    _emit();
  }

  void setFocusOnly(bool value) {
    focusOnly = value;
    hiddenIds.remove(selectedId);
    _emit();
  }

  void toggleVisibility(String id) {
    if (!hiddenIds.add(id)) hiddenIds.remove(id);
    _emit();
  }

  void setFollow(bool value) {
    followMe = value;
    _emit();
  }

  // Inactive UI states suspend requests. Hidden/background states also
  // pause the session, requiring an explicit Resume when the user returns.
  void setForeground(bool foreground, {bool pauseRecording = false}) {
    if (_foreground != foreground) {
      _foreground = foreground;
      _generation++;
      _newSegment = true;
    }
    if (pauseRecording)
      pause(reason: 'App left the foreground. Tap Resume to continue.');
  }

  Future<void> refreshLocation({bool askPermission = false}) async {
    if (!ready || fetching || !_foreground || _disposed) return;
    fetching = true;
    locationAction = LocationAction.none;
    final generation = _generation;
    final recordingId = recording ? activeId : null;
    _emit();
    try {
      final point = await _readLocation(askPermission);
      if (_disposed || !_foreground || generation != _generation) return;
      currentPoint = point;
      if (recordingId != null && activeId == recordingId && recording) {
        active!.addPoint(point, newSegment: _newSegment);
        _newSegment = false;
        message = 'Recording ${active!.name} • ${active!.pointCount} readings';
        unawaited(save());
      } else {
        message =
            'Location updated. ${active == null ? 'Ready to start a route.' : 'Route is paused.'}';
      }
    } catch (error) {
      if (_disposed || generation != _generation) return;
      _newSegment = true;
      if (error is LocationProblem) {
        locationAction = error.action;
        pause(reason: error.message);
        message = error.message;
      } else if (error is TimeoutException) {
        message =
            'GPS timed out. Try Find me; recording retries on the next check.';
      } else {
        message = 'Location unavailable. Check GPS and permissions, then try Find me.';
        debugPrint('Location failed: $error');
      }
    } finally {
      fetching = false;
      _emit();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
    super.dispose();
  }
}
