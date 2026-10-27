import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'route_session.dart';
import 'tracker_controller.dart';

const routeColors = <int>[
  0xff1565c0,
  0xffc62828,
  0xff2e7d32,
  0xff6a1b9a,
  0xffef6c00,
  0xff00838f,
  0xffad1457,
  0xff5d4037,
];
const routeColorNames = <String>[
  'Blue',
  'Red',
  'Green',
  'Purple',
  'Orange',
  'Teal',
  'Pink',
  'Brown',
];

LatLng mapPoint(RoutePoint point) => LatLng(point.latitude, point.longitude);
String distanceText(double meters) => meters < 1000
    ? '${meters.toStringAsFixed(0)} m'
    : '${(meters / 1000).toStringAsFixed(2)} km';
String durationText(Duration duration) {
  final h = duration.inHours;
  final m = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

String dateText(DateTime time) {
  final t = time.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with WidgetsBindingObserver {
  final tracker = TrackerController();
  GoogleMapController? _map;
  RoutePoint? _lastSeenPoint;
  bool _centerPending = false;
  bool _initialViewSet = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    tracker.addListener(_changed);
    final state = WidgetsBinding.instance.lifecycleState;
    tracker.setForeground(state == null || state == AppLifecycleState.resumed);
    unawaited(tracker.initialize());
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (tracker.currentPoint != null &&
        tracker.currentPoint != _lastSeenPoint) {
      _lastSeenPoint = tracker.currentPoint;
      if (_centerPending || tracker.followMe) unawaited(_centerCurrent());
    }
    if (!_initialViewSet && tracker.ready && _map != null) {
      _initialViewSet = true;
      if (tracker.selected?.pointCount != null &&
          tracker.selected!.pointCount > 0) {
        unawaited(_fitSelected());
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    tracker.setForeground(
      state == AppLifecycleState.resumed,
      pauseRecording:
          state == AppLifecycleState.paused ||
          state == AppLifecycleState.hidden ||
          state == AppLifecycleState.detached,
    );
  }

  Future<void> _animate(CameraUpdate update) async {
    final map = _map;
    if (map == null || !mounted) return;
    try {
      await map.animateCamera(update);
    } catch (error) {
      debugPrint('Map camera failed: $error');
      if (mounted) _notice('Could not move the map. Try again.');
    }
  }

  Future<void> _centerCurrent() async {
    final point = tracker.currentPoint;
    if (_map == null || point == null) return;
    _centerPending = false;
    await _animate(CameraUpdate.newLatLngZoom(mapPoint(point), 16));
  }

  Future<void> _findMe() async {
    _centerPending = true;
    // Center immediately if a reading is already available, then refresh.
    await _centerCurrent();
    _centerPending = true;
    await tracker.refreshLocation(askPermission: true);
    if (mounted) await _centerCurrent();
  }

  Future<void> _fitSelected() async {
    final points = tracker.selected?.points.toList() ?? <RoutePoint>[];
    if (points.isEmpty) {
      _notice('This route has no GPS points yet.');
      return;
    }
    tracker.setFollow(false);
    if (points.length == 1) {
      await _animate(CameraUpdate.newLatLngZoom(mapPoint(points.first), 16));
      return;
    }
    var south = points.first.latitude;
    var north = south;
    for (final point in points) {
      south = math.min(south, point.latitude);
      north = math.max(north, point.latitude);
    }
    // Use the smallest longitude arc, including routes crossing +/-180.
    final longitudes = points.map((p) => (p.longitude + 360) % 360).toList()
      ..sort();
    var largestGap = -1.0;
    var gapIndex = 0;
    for (var i = 0; i < longitudes.length; i++) {
      final next = i == longitudes.length - 1
          ? longitudes.first + 360
          : longitudes[i + 1];
      if (next - longitudes[i] > largestGap) {
        largestGap = next - longitudes[i];
        gapIndex = i;
      }
    }
    double signed(double value) => value > 180 ? value - 360 : value;
    final west = signed(longitudes[(gapIndex + 1) % longitudes.length]);
    final east = signed(longitudes[gapIndex]);
    if ((north - south).abs() < 0.00001 && 360 - largestGap < 0.00001) {
      await _animate(CameraUpdate.newLatLngZoom(mapPoint(points.first), 17));
    } else {
      await _animate(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(south, west),
            northeast: LatLng(north, east),
          ),
          55,
        ),
      );
    }
  }

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _editRoute([RouteSession? route]) async {
    final index = tracker.routes.length;
    final result = await showDialog<RouteDetails>(
      context: context,
      builder: (_) => RouteDetailsDialog(
        title: route == null ? 'Start a new route' : 'Edit route',
        initialName: route?.name ?? 'Route ${index + 1}',
        initialColor:
            route?.colorValue ?? routeColors[index % routeColors.length],
        initialPattern:
            route?.pattern ??
            RoutePattern.values[index % RoutePattern.values.length],
      ),
    );
    if (!mounted || result == null) return;
    if (route == null) {
      _centerPending = true;
      tracker.start(result.name, result.color, result.pattern);
    } else {
      tracker.updateRoute(route.id, result.name, result.color, result.pattern);
    }
  }

  Future<void> _deleteRoute(RouteSession route) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this route?'),
        content: Text(
          'Delete "${route.name}" and its ${route.pointCount} recorded points? '
          '${tracker.activeId == route.id ? 'Recording will stop. ' : ''}This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (mounted && confirmed == true) tracker.deleteRoute(route.id);
  }

  Future<void> _finishRoute() async {
    final route = tracker.active;
    if (route == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Finish this route?'),
        content: Text(
          'Save "${route.name}" as a finished session. Use Pause if you want to resume it later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Finish'),
          ),
        ],
      ),
    );
    if (mounted && confirmed == true) tracker.finish();
  }

  Future<void> _showRoutes() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(sheetContext).size.height * 0.72,
          child: AnimatedBuilder(
            animation: tracker,
            builder: (context, _) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Saved routes (${tracker.routes.length})',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close routes',
                        onPressed: () => Navigator.pop(sheetContext),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                  child: Text(
                    'Tap a route to select it. In Compare mode, the eye buttons hide or show routes.',
                  ),
                ),
                Expanded(
                  child: tracker.routes.isEmpty
                      ? const Center(
                          child: Text('No routes yet. Tap New route to begin.'),
                        )
                      : ListView.builder(
                          itemCount: tracker.routes.length,
                          itemBuilder: (context, index) {
                            final route = tracker.routes[index];
                            final isSelected = tracker.selectedId == route.id;
                            return Card(
                              margin: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 5,
                              ),
                              color: isSelected
                                  ? Theme.of(context)
                                        .colorScheme
                                        .primaryContainer
                                  : null,
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: Color(route.colorValue),
                                  child: Text(
                                    '${index + 1}',
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                ),
                                title: Text(
                                  route.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${route.status.name.toUpperCase()} • ${route.pattern.name}\n'
                                  '${dateText(route.createdAt)}\n'
                                  '${distanceText(route.distanceMeters)} • ${route.pointCount} readings',
                                ),
                                isThreeLine: true,
                                onTap: () {
                                  tracker.select(route.id);
                                  Navigator.pop(sheetContext);
                                  unawaited(_fitSelected());
                                },
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: tracker.focusOnly
                                          ? 'Switch to Compare to hide/show'
                                          : 'Hide or show route',
                                      onPressed: tracker.focusOnly
                                          ? null
                                          : () => tracker.toggleVisibility(
                                              route.id,
                                            ),
                                      icon: Icon(
                                        tracker.hiddenIds.contains(route.id)
                                            ? Icons.visibility_off
                                            : Icons.visibility,
                                      ),
                                    ),
                                    PopupMenuButton<String>(
                                      tooltip: 'Route options',
                                      onSelected: (value) {
                                        if (value == 'edit')
                                          unawaited(_editRoute(route));
                                        if (value == 'delete')
                                          unawaited(_deleteRoute(route));
                                      },
                                      itemBuilder: (_) => const [
                                        PopupMenuItem(
                                          value: 'edit',
                                          child: Text('Name, color & style'),
                                        ),
                                        PopupMenuItem(
                                          value: 'delete',
                                          child: Text('Delete route'),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<PatternItem> _patterns(RoutePattern pattern) => switch (pattern) {
    RoutePattern.solid => [],
    RoutePattern.dashed => [PatternItem.dash(22), PatternItem.gap(12)],
    RoutePattern.dotted => [PatternItem.dot, PatternItem.gap(12)],
  };

  Set<Polyline> _polylines() {
    final lines = <Polyline>{};
    final routes = tracker.displayedRoutes;
    for (var r = 0; r < routes.length; r++) {
      final route = routes[r];
      final selected = route.id == tracker.selectedId;
      for (var s = 0; s < route.segments.length; s++) {
        final segment = route.segments[s];
        if (segment.length < 2) continue;
        final points = segment.map(mapPoint).toList();
        if (selected) {
          lines.add(
            Polyline(
              polylineId: PolylineId('${route.id}_${s}_outline'),
              points: points,
              width: 12,
              color: Colors.white.withAlpha(230),
              zIndex: 100000,
              patterns: _patterns(route.pattern),
            ),
          );
        }
        lines.add(
          Polyline(
            polylineId: PolylineId('${route.id}_$s'),
            points: points,
            color: Color(route.colorValue).withAlpha(selected ? 255 : 135),
            width: selected ? 7 : 4,
            zIndex: selected ? 100001 : r,
            patterns: _patterns(route.pattern),
            consumeTapEvents: true,
            onTap: () => tracker.select(route.id),
          ),
        );
      }
    }
    return lines;
  }

  Set<Marker> _markers() {
    final markers = <Marker>{};
    final route = tracker.selected;
    if (route != null &&
        !tracker.hiddenIds.contains(route.id) &&
        route.firstPoint != null) {
      final first = route.firstPoint!;
      final last = route.lastPoint!;
      final samePlace = distanceBetween(first, last) < 3;
      final hue = HSVColor.fromColor(Color(route.colorValue)).hue;
      markers.add(
        Marker(
          markerId: MarkerId('${route.id}_start'),
          position: mapPoint(first),
          icon: BitmapDescriptor.defaultMarkerWithHue(hue),
          infoWindow: InfoWindow(
            title: '${route.name} • ${samePlace ? 'Start / latest' : 'Start'}',
            snippet: dateText(first.time),
          ),
        ),
      );
      if (!samePlace) {
        markers.add(
          Marker(
            markerId: MarkerId('${route.id}_end'),
            position: mapPoint(last),
            icon: BitmapDescriptor.defaultMarkerWithHue(hue),
            infoWindow: InfoWindow(
              title:
                  '${route.name} • ${route.status == RouteStatus.finished ? 'Finish' : 'Latest'}',
              snippet: dateText(last.time),
            ),
          ),
        );
      }
    }
    final current = tracker.currentPoint;
    if (current != null) {
      markers.add(
        Marker(
          markerId: const MarkerId('current_location'),
          position: mapPoint(current),
          zIndexInt: 200001,
          infoWindow: InfoWindow(
            title: 'My latest location',
            snippet:
                'Lat: ${current.latitude.toStringAsFixed(6)}, '
                'Lng: ${current.longitude.toStringAsFixed(6)} '
                '(±${current.accuracy.toStringAsFixed(0)} m)',
          ),
        ),
      );
    }
    return markers;
  }

  @override
  Widget build(BuildContext context) {
    final selected = tracker.selected;
    final active = tracker.active;
    final current = tracker.currentPoint;
    return Scaffold(
      appBar: AppBar(
        title: const Text('RouteLog'),
        actions: [
          IconButton(
            tooltip: 'Saved routes',
            onPressed: tracker.ready ? _showRoutes : null,
            icon: const Icon(Icons.route),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (tracker.loading) const LinearProgressIndicator(),
            if (tracker.loadError != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    Text(tracker.loadError!),
                    TextButton(
                      onPressed: tracker.initialize,
                      child: const Text('Retry loading'),
                    ),
                  ],
                ),
              ),
            if (tracker.ready)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 190),
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (selected != null)
                          Row(
                            children: [
                              Icon(
                                Icons.circle,
                                color: Color(selected.colorValue),
                                size: 14,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  selected.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium,
                                ),
                              ),
                              IconButton(
                                tooltip: 'Edit name, color and style',
                                onPressed: () => _editRoute(selected),
                                icon: const Icon(Icons.edit_outlined, size: 20),
                              ),
                            ],
                          ),
                        if (selected != null)
                          Text(
                            '${distanceText(selected.distanceMeters)} estimated • '
                            '${durationText(selected.sampledDuration)} sampled • ${selected.pointCount} points',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        Wrap(
                          spacing: 8,
                          children: [
                            ChoiceChip(
                              label: const Text('Selected only'),
                              selected: tracker.focusOnly,
                              onSelected: (_) => tracker.setFocusOnly(true),
                            ),
                            ChoiceChip(
                              label: const Text('Compare'),
                              selected: !tracker.focusOnly,
                              onSelected: (_) => tracker.setFocusOnly(false),
                            ),
                            FilterChip(
                              label: const Text('Follow me'),
                              selected: tracker.followMe,
                              onSelected: (value) {
                                tracker.setFollow(value);
                                if (value) unawaited(_findMe());
                              },
                            ),
                          ],
                        ),
                        Text(
                          tracker.focusOnly
                              ? 'Only the selected route is shown.'
                              : 'Selected route is bold. Use Saved routes to select or hide overlaps.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Expanded(
              child: Stack(
                children: [
                  GoogleMap(
                    initialCameraPosition: const CameraPosition(
                      target: LatLng(23.8103, 90.4125),
                      zoom: 13,
                    ),
                    padding: const EdgeInsets.only(bottom: 110),
                    onMapCreated: (controller) {
                      if (!mounted) {
                        controller.dispose();
                        return;
                      }
                      _map = controller;
                      _changed();
                      if (_centerPending) unawaited(_centerCurrent());
                    },
                    polylines: _polylines(),
                    markers: _markers(),
                    circles: {
                      if (current != null)
                        Circle(
                          circleId: const CircleId('current_position'),
                          center: mapPoint(current),
                          radius: current.accuracy,
                          fillColor: Colors.blue.withAlpha(25),
                          strokeColor: Colors.blue.withAlpha(100),
                          strokeWidth: 2,
                          zIndex: 200000,
                          consumeTapEvents: true,
                          onTap: () => _notice(
                            'Latest GPS: ${current.latitude.toStringAsFixed(6)}, '
                            '${current.longitude.toStringAsFixed(6)} • accuracy ±${current.accuracy.toStringAsFixed(0)} m',
                          ),
                        ),
                    },
                  ),
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: Column(
                      children: [
                        FloatingActionButton.small(
                          heroTag: 'fit-route',
                          tooltip: 'Fit selected route',
                          onPressed: selected?.firstPoint == null
                              ? null
                              : _fitSelected,
                          child: const Icon(Icons.fit_screen),
                        ),
                        const SizedBox(height: 8),
                        FloatingActionButton.small(
                          heroTag: 'find-me',
                          tooltip: 'Find me / recenter',
                          onPressed: tracker.ready && !tracker.fetching
                              ? _findMe
                              : null,
                          child: const Icon(Icons.my_location),
                        ),
                      ],
                    ),
                  ),
                  if (tracker.fetching)
                    const Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: LinearProgressIndicator(),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                tracker.message,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (tracker.locationAction != LocationAction.none)
                TextButton(
                  onPressed: () async {
                    if (tracker.locationAction ==
                        LocationAction.deviceSettings) {
                      await Geolocator.openLocationSettings();
                    } else {
                      await Geolocator.openAppSettings();
                    }
                  },
                  child: const Text('Open settings'),
                ),
              if (tracker.saveError != null)
                TextButton(
                  onPressed: tracker.save,
                  child: Text(tracker.saveError!),
                )
              else if (tracker.ready)
                Text(
                  tracker.saving
                      ? 'Saving changes...'
                      : 'Saved locally • foreground recording only',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  if (active == null)
                    FilledButton.icon(
                      onPressed: tracker.ready ? () => _editRoute() : null,
                      icon: const Icon(Icons.add),
                      label: const Text('New route'),
                    )
                  else ...[
                    FilledButton.icon(
                      onPressed: () {
                        if (tracker.recording) {
                          tracker.pause();
                        } else {
                          tracker.resume();
                        }
                      },
                      icon: Icon(
                        tracker.recording ? Icons.pause : Icons.play_arrow,
                      ),
                      label: Text(tracker.recording ? 'Pause' : 'Resume'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _finishRoute,
                      icon: const Icon(Icons.stop),
                      label: const Text('Finish'),
                    ),
                  ],
                  OutlinedButton.icon(
                    onPressed: tracker.ready ? _showRoutes : null,
                    icon: const Icon(Icons.list),
                    label: const Text('Routes'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    tracker.removeListener(_changed);
    tracker.dispose();
    _map?.dispose();
    super.dispose();
  }
}

class RouteDetails {
  const RouteDetails(this.name, this.color, this.pattern);
  final String name;
  final int color;
  final RoutePattern pattern;
}

class RouteDetailsDialog extends StatefulWidget {
  const RouteDetailsDialog({
    super.key,
    required this.title,
    required this.initialName,
    required this.initialColor,
    required this.initialPattern,
  });
  final String title;
  final String initialName;
  final int initialColor;
  final RoutePattern initialPattern;
  @override
  State<RouteDetailsDialog> createState() => _RouteDetailsDialogState();
}

class _RouteDetailsDialogState extends State<RouteDetailsDialog> {
  late final TextEditingController _name;
  late int _color;
  late RoutePattern _pattern;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initialName);
    _color = widget.initialColor;
    _pattern = widget.initialPattern;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 340,
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                maxLength: 60,
                decoration: const InputDecoration(labelText: 'Route name'),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Enter a route name.'
                    : null,
              ),
              const SizedBox(height: 12),
              const Text('Route color'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < routeColors.length; i++)
                    Semantics(
                      label: routeColorNames[i],
                      selected: _color == routeColors[i],
                      button: true,
                      child: Tooltip(
                        message: routeColorNames[i],
                        child: InkWell(
                          onTap: () => setState(() => _color = routeColors[i]),
                          borderRadius: BorderRadius.circular(24),
                          child: CircleAvatar(
                            radius: 22,
                            backgroundColor: Color(routeColors[i]),
                            child: _color == routeColors[i]
                                ? const Icon(Icons.check, color: Colors.white)
                                : null,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              const Text('Line style'),
              Wrap(
                spacing: 6,
                children: [
                  for (final pattern in RoutePattern.values)
                    ChoiceChip(
                      label: Text(pattern.name),
                      selected: _pattern == pattern,
                      onSelected: (_) => setState(() => _pattern = pattern),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Different names and line styles help distinguish routes that share a color.',
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (_formKey.currentState!.validate()) {
            Navigator.pop(
              context,
              RouteDetails(_name.text.trim(), _color, _pattern),
            );
          }
        },
        child: const Text('Save'),
      ),
    ],
  );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }
}
