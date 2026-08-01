import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

/// Raised when a GPS fix can't be obtained — services off, permission denied,
/// or no lock. The presence gate treats this as the "no_fix" case (inspection
/// allowed only with an override reason).
class LocationUnavailable implements Exception {
  const LocationUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Thin wrapper over geolocator for the presence-gated inspection flow.
///
/// GPS works without mobile data, so everything here functions fully offline —
/// only map *tiles* need a prior download. Reuses the same permission dance the
/// map tab's "my location" button already used.
class LocationService {
  LocationService._();
  static final LocationService instance = LocationService._();

  /// Ensures location services are on and permission is granted, throwing a
  /// [LocationUnavailable] with a user-facing message otherwise.
  static Future<void> ensureReady() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const LocationUnavailable('Turn on location services (GPS) and try again.');
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      throw const LocationUnavailable('Location permission denied — enable it in Settings.');
    }
  }

  /// How long a one-shot fix may take before it counts as "no fix".
  ///
  /// Load-bearing: `getCurrentPosition` at [LocationAccuracy.best] waits
  /// *indefinitely* when the sky view is blocked — under a tower, inside a
  /// switchyard building, on a phone whose GNSS is cold. The presence dialog that
  /// awaits it is `barrierDismissible: false`, so with no limit the inspector was
  /// left in a modal spinner with no way out and the tower could not be
  /// inspected at all. Timing out instead routes them to the audited no-fix
  /// override, which is the designed fallback.
  static const Duration fixTimeout = Duration(seconds: 20);

  /// A single high-accuracy fix. Throws [LocationUnavailable] on failure.
  static Future<Position> currentFix() async {
    await ensureReady();
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: fixTimeout,
        ),
      );
    } on TimeoutException {
      throw const LocationUnavailable(
          'No GPS fix within 20 s — the sky view may be blocked. '
          'You can continue with a reason.');
    } catch (e) {
      throw LocationUnavailable('Could not get a GPS fix: $e');
    }
  }

  /// A live position stream (best accuracy, ~5 m distance filter) for Home's
  /// nearest-towers list. Callers must handle errors (which surface as the
  /// no-fix case).
  static Stream<Position> positionStream() {
    return Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 5,
      ),
    );
  }

  /// Great-circle distance in metres between two points (haversine, offline).
  static double distanceMeters(double lat1, double lng1, double lat2, double lng2) =>
      Geolocator.distanceBetween(lat1, lng1, lat2, lng2);

  static double distanceTo(LatLng from, double lat, double lng) =>
      Geolocator.distanceBetween(from.latitude, from.longitude, lat, lng);
}
