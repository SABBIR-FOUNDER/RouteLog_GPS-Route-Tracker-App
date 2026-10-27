import 'dart:math' as math;

enum RouteStatus { recording, paused, finished }

enum RoutePattern { solid, dashed, dotted }

class RoutePoint {
  const RoutePoint(this.latitude, this.longitude, this.time, this.accuracy);

  final double latitude;
  final double longitude;
  final DateTime time;
  final double accuracy;

  Map<String, dynamic> toJson() => {
    'lat': latitude,
    'lng': longitude,
    'time': time.toUtc().toIso8601String(),
    'accuracy': accuracy,
  };

  factory RoutePoint.fromJson(Map<String, dynamic> json) {
    final lat = (json['lat'] as num).toDouble();
    final lng = (json['lng'] as num).toDouble();
    final accuracy = (json['accuracy'] as num).toDouble();
    if (!lat.isFinite ||
        !lng.isFinite ||
        lat.abs() > 90 ||
        lng.abs() > 180 ||
        !accuracy.isFinite ||
        accuracy < 0) {
      throw const FormatException('Invalid coordinates or accuracy.');
    }
    return RoutePoint(
      lat,
      lng,
      DateTime.parse(json['time'] as String),
      accuracy,
    );
  }
}

class RouteSession {
  RouteSession({
    required this.id,
    required this.name,
    required this.colorValue,
    required this.createdAt,
    this.pattern = RoutePattern.solid,
    this.status = RouteStatus.recording,
    List<List<RoutePoint>>? segments,
  }) : segments = segments ?? [];

  final String id;
  String name;
  int colorValue;
  final DateTime createdAt;
  RoutePattern pattern;
  RouteStatus status;
  final List<List<RoutePoint>> segments;

  Iterable<RoutePoint> get points => segments.expand((segment) => segment);
  int get pointCount => segments.fold(0, (n, segment) => n + segment.length);
  RoutePoint? get firstPoint => segments.isEmpty ? null : segments.first.first;
  RoutePoint? get lastPoint => segments.isEmpty ? null : segments.last.last;

  void addPoint(RoutePoint point, {required bool newSegment}) {
    if (newSegment || segments.isEmpty) {
      segments.add([point]);
    } else {
      segments.last.add(point);
    }
  }

  // Never count distance or time across a paused/unrecorded gap.
  double get distanceMeters {
    var total = 0.0;
    for (final segment in segments) {
      for (var i = 1; i < segment.length; i++) {
        total += distanceBetween(segment[i - 1], segment[i]);
      }
    }
    return total;
  }

  Duration get sampledDuration {
    var milliseconds = 0;
    for (final segment in segments) {
      if (segment.length > 1) {
        milliseconds += math.max(
          0,
          segment.last.time.difference(segment.first.time).inMilliseconds,
        );
      }
    }
    return Duration(milliseconds: milliseconds);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'color': colorValue,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'pattern': pattern.name,
    'status': status.name,
    'segments': segments.map((s) => s.map((p) => p.toJson()).toList()).toList(),
  };

  factory RouteSession.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String;
    final name = json['name'] as String;
    final color = json['color'] as int;
    if (id.isEmpty || name.trim().isEmpty || color < 0 || color > 0xffffffff) {
      throw const FormatException('Invalid route details.');
    }
    final segments = (json['segments'] as List).map((raw) {
      final segment = (raw as List)
          .map(
            (point) =>
                RoutePoint.fromJson(Map<String, dynamic>.from(point as Map)),
          )
          .toList();
      if (segment.isEmpty) throw const FormatException('Empty segment.');
      return segment;
    }).toList();
    return RouteSession(
      id: id,
      name: name,
      colorValue: color,
      createdAt: DateTime.parse(json['createdAt'] as String),
      pattern: RoutePattern.values.byName(json['pattern'] as String),
      status: RouteStatus.values.byName(json['status'] as String),
      segments: segments,
    );
  }
}

double distanceBetween(RoutePoint a, RoutePoint b) {
  const radians = math.pi / 180;
  final dLat = (b.latitude - a.latitude) * radians;
  final dLng = (b.longitude - a.longitude) * radians;
  final h =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(a.latitude * radians) *
          math.cos(b.latitude * radians) *
          math.pow(math.sin(dLng / 2), 2);
  return 6371000 * 2 * math.asin(math.sqrt(h.clamp(0.0, 1.0)));
}
