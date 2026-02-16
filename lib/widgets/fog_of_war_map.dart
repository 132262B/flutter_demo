import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../models/location_point.dart';
import '../services/database_service.dart';
import '../services/location_service.dart';
import 'fog_overlay_painter.dart';

class FogOfWarMap extends StatefulWidget {
  const FogOfWarMap({super.key});

  @override
  State<FogOfWarMap> createState() => _FogOfWarMapState();
}

class _FogOfWarMapState extends State<FogOfWarMap> {
  final MapController _mapController = MapController();
  final DatabaseService _dbService = DatabaseService();
  final LocationService _locationService = LocationService();

  List<LatLng> _visitedPoints = [];
  LatLng? _currentPosition;
  StreamSubscription<Position>? _positionSubscription;
  bool _permissionDenied = false;
  bool _loading = true;
  double _currentZoom = 15.0;

  static const double _revealRadiusMeters = 500;
  static const double _deduplicateDistanceMeters = 25;
  static const Distance _distance = Distance();
  static const List<double> _zoomSteps = [3, 5, 7, 9, 11, 13, 15, 17];

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    final savedPoints = await _dbService.getAllPoints();
    final points =
        savedPoints.map((p) => LatLng(p.latitude, p.longitude)).toList();

    setState(() {
      _visitedPoints = points;
    });

    final hasPermission = await _locationService.requestPermission();
    if (!hasPermission) {
      setState(() {
        _permissionDenied = true;
        _loading = false;
      });
      return;
    }

    final currentPos = await _locationService.getCurrentPosition();
    final currentLatLng = LatLng(currentPos.latitude, currentPos.longitude);

    setState(() {
      _currentPosition = currentLatLng;
      _loading = false;
    });

    _addPointIfNew(currentLatLng);
    _mapController.move(currentLatLng, 15.0);

    _positionSubscription =
        _locationService.getPositionStream().listen((position) {
      final newPoint = LatLng(position.latitude, position.longitude);
      setState(() {
        _currentPosition = newPoint;
      });
      _addPointIfNew(newPoint);
    });
  }

  void _addPointIfNew(LatLng newPoint) {
    if (!_isNewArea(newPoint)) return;

    final locationPoint = LocationPoint(
      latitude: newPoint.latitude,
      longitude: newPoint.longitude,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    _dbService.insertPoint(locationPoint);
    setState(() {
      _visitedPoints.add(newPoint);
    });
  }

  bool _isNewArea(LatLng newPoint) {
    for (final existing in _visitedPoints) {
      if (_distance.as(LengthUnit.Meter, existing, newPoint) <
          _deduplicateDistanceMeters) {
        return false;
      }
    }
    return true;
  }

  Widget _zoomButton(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Icon(icon, color: Colors.white, size: 20),
    );
  }

  double _metersToPixels(MapCamera camera, LatLng point, double meters) {
    final origin = camera.latLngToScreenOffset(point);
    final offsetPoint = _distance.offset(point, meters, 180);
    final target = camera.latLngToScreenOffset(offsetPoint);
    return (origin - target).distance;
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Colors.white),
              SizedBox(height: 16),
              Text('위치를 확인하고 있습니다...', style: TextStyle(color: Colors.white)),
            ],
          ),
        ),
      );
    }

    if (_permissionDenied) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.location_off, color: Colors.white54, size: 64),
              const SizedBox(height: 16),
              const Text(
                '위치 권한이 필요합니다',
                style: TextStyle(color: Colors.white, fontSize: 18),
              ),
              const SizedBox(height: 8),
              const Text(
                '지도를 탐험하려면 위치 접근을\n허용해주세요.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () async {
                  await Geolocator.openAppSettings();
                },
                child: const Text('설정으로 이동'),
              ),
            ],
          ),
        ),
      );
    }

    final currentStepIndex =
        _zoomSteps.indexWhere((z) => (z - _currentZoom).abs() < 1.5);

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
        mapController: _mapController,
        options: MapOptions(
          initialCenter: _currentPosition ?? const LatLng(35.1531, 129.1186),
          initialZoom: 15.0,
          minZoom: 3,
          maxZoom: 17,
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
          ),
          onPositionChanged: (camera, hasGesture) {
            if (_currentZoom != camera.zoom) {
              setState(() {
                _currentZoom = camera.zoom;
              });
            }
          },
          onMapEvent: (event) {
            if (event is MapEventMoveEnd ||
                event is MapEventFlingAnimationEnd ||
                event is MapEventDoubleTapZoomEnd ||
                event is MapEventScrollWheelZoom) {
              final currentZoom = _mapController.camera.zoom;
              final nearest = _zoomSteps.reduce((a, b) =>
                  (a - currentZoom).abs() < (b - currentZoom).abs() ? a : b);
              if ((currentZoom - nearest).abs() > 0.01) {
                _mapController.move(
                    _mapController.camera.center, nearest);
              }
            }
          },
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.example.flutter_demo',
          ),
          // Fog overlay
          Builder(builder: (context) {
            final camera = MapCamera.of(context);
            final screenPoints = <Offset>[];
            final radii = <double>[];

            final bounds = camera.visibleBounds;
            const margin = 0.01;

            for (final point in _visitedPoints) {
              if (point.latitude < bounds.south - margin ||
                  point.latitude > bounds.north + margin ||
                  point.longitude < bounds.west - margin ||
                  point.longitude > bounds.east + margin) {
                continue;
              }
              final screenPoint = camera.latLngToScreenOffset(point);
              screenPoints.add(screenPoint);
              radii.add(_metersToPixels(camera, point, _revealRadiusMeters));
            }

            return CustomPaint(
              size: Size.infinite,
              painter: FogOverlayPainter(
                revealedScreenPoints: screenPoints,
                revealRadii: radii,
              ),
            );
          }),
          // GPS point markers
          MarkerLayer(
            markers: _visitedPoints.map((point) {
              return Marker(
                point: point,
                width: 8,
                height: 8,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.7),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1),
                  ),
                ),
              );
            }).toList(),
          ),
          // Current position marker
          if (_currentPosition != null)
            MarkerLayer(
              markers: [
                Marker(
                  point: _currentPosition!,
                  width: 20,
                  height: 20,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.blue,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.blue.withValues(alpha: 0.4),
                          blurRadius: 8,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          SimpleAttributionWidget(
            source: Text(
              'OSM',
              style: TextStyle(
                color: Colors.black.withValues(alpha: 0.15),
                fontSize: 8,
              ),
            ),
            backgroundColor: Colors.transparent,
          ),
        ],
      ),
          // Zoom control
          Positioned(
            left: 12,
            top: 0,
            bottom: 0,
            child: Center(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(24),
                ),
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _zoomButton(Icons.add, () {
                      if (currentStepIndex < _zoomSteps.length - 1) {
                        _mapController.move(
                          _mapController.camera.center,
                          _zoomSteps[currentStepIndex + 1],
                        );
                      }
                    }),
                    const SizedBox(height: 4),
                    ...List.generate(_zoomSteps.length, (i) {
                      final stepIndex = _zoomSteps.length - 1 - i;
                      final isActive = stepIndex == currentStepIndex;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: GestureDetector(
                          onTap: () {
                            _mapController.move(
                              _mapController.camera.center,
                              _zoomSteps[stepIndex],
                            );
                          },
                          child: Container(
                            width: 6,
                            height: isActive ? 16 : 10,
                            decoration: BoxDecoration(
                              color: isActive
                                  ? Colors.white
                                  : Colors.white.withValues(alpha: 0.3),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      );
                    }),
                    const SizedBox(height: 4),
                    _zoomButton(Icons.remove, () {
                      if (currentStepIndex > 0) {
                        _mapController.move(
                          _mapController.camera.center,
                          _zoomSteps[currentStepIndex - 1],
                        );
                      }
                    }),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () async {
                    final pos = await _locationService.getCurrentPosition();
                    final newPoint = LatLng(pos.latitude, pos.longitude);
                    setState(() {
                      _currentPosition = newPoint;
                    });
                    _addPointIfNew(newPoint);
                    _mapController.move(newPoint, 15.0);
                  },
                  icon: const Icon(Icons.add_location_alt),
                  label: const Text('현재 위치 등록'),
                ),
              ),
              const SizedBox(width: 12),
              FloatingActionButton.small(
                heroTag: 'myLocation',
                onPressed: () {
                  if (_currentPosition != null) {
                    _mapController.move(_currentPosition!, 15.0);
                  }
                },
                child: const Icon(Icons.my_location),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
