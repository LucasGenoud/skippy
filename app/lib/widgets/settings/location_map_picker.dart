import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// OpenStreetMap's standard tiles: no key, no account, and no Google service,
/// which is the rule the rest of the app follows. Their usage policy asks for
/// an identifying User-Agent, which [TileLayer] builds from the package name
/// below, and for the attribution shown in the corner.
const String _tileUrlTemplate =
    'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const String _userAgentPackageName = 'com.lucasgenoud.skippy';
const String _attribution = '© OpenStreetMap contributors';

/// Where a saved place is, and the handle for moving it.
///
/// The pin sits in the middle of the viewport and the map moves under it,
/// rather than being a marker to drag: dragging a small target with the thumb
/// that is also covering it is the fiddly way to do this on a phone, and it
/// leaves nothing to aim at once the place is off-screen. Panning, pinching
/// and tapping all end at the same answer, which is the map's centre.
///
/// Coordinates are reported when a gesture *finishes*. Reporting every frame
/// would rewrite the coordinate fields (and rebuild the form around them) all
/// through a pan, for text nobody can read while it is moving.
class LocationMapPicker extends StatefulWidget {
  final double latitude;
  final double longitude;

  /// Drawn as a circle around the pin, so "150 m" is a size on the ground
  /// rather than a number in a field.
  final double radiusMeters;

  final ValueChanged<({double latitude, double longitude})> onMoved;
  final double height;

  const LocationMapPicker({
    super.key,
    required this.latitude,
    required this.longitude,
    required this.radiusMeters,
    required this.onMoved,
    this.height = 220,
  });

  @override
  State<LocationMapPicker> createState() => _LocationMapPickerState();
}

class _LocationMapPickerState extends State<LocationMapPicker> {
  static const double _initialZoom = 15;

  /// Two coordinates closer than this are the same place. It is a shade wider
  /// than the six decimals the fields carry (about 10 cm), so a reported
  /// coordinate coming back rounded never reads as a new one, which is what
  /// would turn "the map moved, write the fields" and "the fields changed,
  /// move the map" into a loop.
  static const double _epsilon = 0.000001;

  final _controller = MapController();
  StreamSubscription<MapEvent>? _events;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _events = _controller.mapEventStream.listen((event) {
      if (event is MapEventMoveEnd ||
          event is MapEventFlingAnimationEnd ||
          event is MapEventDoubleTapZoomEnd) {
        _report(_controller.camera.center);
      }
    });
  }

  @override
  void dispose() {
    _events?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(LocationMapPicker old) {
    super.didUpdateWidget(old);
    if (!_ready) return;
    final incoming = LatLng(widget.latitude, widget.longitude);
    // The coordinates were typed, or "use current location" replaced them:
    // follow them. A gesture never reaches here, it moved the camera itself.
    if (_sameSpot(incoming, _controller.camera.center)) return;
    _controller.move(incoming, _controller.camera.zoom);
  }

  bool _sameSpot(LatLng a, LatLng b) =>
      (a.latitude - b.latitude).abs() < _epsilon &&
      (a.longitude - b.longitude).abs() < _epsilon;

  void _report(LatLng point) {
    if (_sameSpot(point, LatLng(widget.latitude, widget.longitude))) return;
    widget.onMoved((latitude: point.latitude, longitude: point.longitude));
  }

  /// A tap is a coarse "over there" rather than a precise placement, so the
  /// map moves to it and the pin ends up on it, instead of the pin jumping out
  /// from under the finger.
  void _recentreOn(LatLng point) {
    _controller.move(point, _controller.camera.zoom);
    _report(point);
  }

  void _zoomBy(double delta) {
    final zoom = (_controller.camera.zoom + delta).clamp(2.0, 19.0);
    _controller.move(_controller.camera.center, zoom);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: widget.height,
        child: Stack(
          alignment: Alignment.center,
          children: [
            FlutterMap(
              mapController: _controller,
              options: MapOptions(
                initialCenter: LatLng(widget.latitude, widget.longitude),
                initialZoom: _initialZoom,
                minZoom: 2,
                maxZoom: 19,
                backgroundColor: scheme.surfaceContainerHighest,
                // A heading means nothing to a saved place, and a rotated map
                // only makes the pin harder to read.
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                ),
                onMapReady: () => setState(() => _ready = true),
                onTap: (_, point) => _recentreOn(point),
              ),
              children: [
                TileLayer(
                  urlTemplate: _tileUrlTemplate,
                  userAgentPackageName: _userAgentPackageName,
                  // Offline, or on a network that cannot reach OSM: the pin
                  // and the radius still draw over the plain background, and
                  // the coordinate fields still work.
                  errorTileCallback: (_, _, _) {},
                ),
                // Reads the live camera instead of state of its own, so the
                // circle tracks the pin during a pan without rebuilding the
                // map (or the form around it) on every frame.
                Builder(
                  builder: (context) => CircleLayer(
                    circles: [
                      CircleMarker(
                        point: MapCamera.of(context).center,
                        radius: widget.radiusMeters,
                        useRadiusInMeter: true,
                        color: scheme.primary.withValues(alpha: 0.16),
                        borderColor: scheme.primary,
                        borderStrokeWidth: 2,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            // Above the map and out of the gesture arena, so the whole
            // surface stays draggable, including under the pin.
            IgnorePointer(
              child: Padding(
                // The tip of the pin is what sits on the spot, so the icon
                // rides half its height above the centre.
                padding: const EdgeInsets.only(bottom: 36),
                child: Icon(
                  Icons.location_on,
                  size: 36,
                  color: scheme.primary,
                  shadows: const [
                    Shadow(blurRadius: 4, color: Color(0x66000000)),
                  ],
                ),
              ),
            ),
            Positioned(
              right: 8,
              top: 8,
              child: Column(
                children: [
                  _MapButton(
                    icon: Icons.add,
                    tooltip: 'Zoom in',
                    onPressed: () => _zoomBy(1),
                  ),
                  const SizedBox(height: 6),
                  _MapButton(
                    icon: Icons.remove,
                    tooltip: 'Zoom out',
                    onPressed: () => _zoomBy(-1),
                  ),
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                child: ColoredBox(
                  color: scheme.surface.withValues(alpha: 0.72),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    child: Text(
                      _attribution,
                      textAlign: TextAlign.right,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MapButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _MapButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface.withValues(alpha: 0.9),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(icon, size: 18, color: scheme.onSurface),
          ),
        ),
      ),
    );
  }
}
