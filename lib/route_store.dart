import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'route_session.dart';

abstract class SessionRepository {
  Future<List<RouteSession>> load();
  Future<void> save(List<RouteSession> routes);
}

class JsonSessionRepository implements SessionRepository {
  JsonSessionRepository({Future<Directory> Function()? directoryProvider})
    : _directoryProvider =
          directoryProvider ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _directoryProvider;
  Future<void> _writeTail = Future<void>.value();

  Future<File> _file() async {
    final directory = await _directoryProvider();
    await directory.create(recursive: true);
    return File(
      '${directory.path}${Platform.pathSeparator}route_sessions_v2.json',
    );
  }

  @override
  Future<List<RouteSession>> load() async {
    final file = await _file();
    if (!await file.exists()) return [];
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map ||
        decoded['version'] != 2 ||
        decoded['routes'] is! List) {
      throw const FormatException('Unsupported or damaged route file.');
    }
    final routes = (decoded['routes'] as List)
        .map(
          (item) =>
              RouteSession.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList();
    if (routes.map((route) => route.id).toSet().length != routes.length) {
      throw const FormatException('Duplicate route IDs.');
    }
    if (routes.where((r) => r.status != RouteStatus.finished).length > 1) {
      throw const FormatException('More than one unfinished route.');
    }
    return routes;
  }

  @override
  Future<void> save(List<RouteSession> routes) {
    // Snapshot NOW. Later changes cannot mutate a queued write.
    final contents = jsonEncode({
      'version': 2,
      'routes': routes.map((route) => route.toJson()).toList(),
    });
    // Writes stay ordered, so an older save cannot undo a deletion or recolor.
    final operation = _writeTail.then((_) async {
      final file = await _file();
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(contents, flush: true);
      await temporary.rename(file.path);
    });
    // Keep the queue usable after a failure; callers still receive the error.
    _writeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }
}
