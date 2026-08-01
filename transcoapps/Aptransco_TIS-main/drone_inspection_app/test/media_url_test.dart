import 'package:flutter_test/flutter_test.dart';

import 'package:drone_inspection_app/services/api_service.dart';
import 'package:drone_inspection_app/services/line_inspection_api.dart';

/// The two URL-building rules every request and every photo depends on.
///
/// Both were wrong in ways nothing else could catch: `flutter analyze` sees
/// well-typed string concatenation, and no widget test reaches a real URL. The
/// symptoms were "no inspection photo ever loads" and "every call 404s after
/// changing the server", neither of which points at a line of code.
void main() {
  // setBaseUrl persists best-effort and sets the in-memory override first, so it
  // works in a plain test with no SharedPreferences mock.
  tearDown(() => ApiService.setBaseUrl(''));

  group('base URL normalisation', () {
    test('strips a trailing slash so paths never double up', () async {
      await ApiService.setBaseUrl('http://192.168.137.1:8000/inspection/api/');
      expect(ApiService.baseUrl, 'http://192.168.137.1:8000/inspection/api');
      // The shape every call builds. `…/api//lines/` is what broke.
      expect('${ApiService.baseUrl}/lines/',
          'http://192.168.137.1:8000/inspection/api/lines/');
    });

    test('strips repeated trailing slashes and surrounding whitespace', () async {
      await ApiService.setBaseUrl('  http://10.0.0.5:8000/inspection/api//  ');
      expect(ApiService.baseUrl, 'http://10.0.0.5:8000/inspection/api');
    });

    test('a blank override falls back to the compile-time default', () async {
      await ApiService.setBaseUrl('');
      expect(ApiService.hasBaseUrlOverride, isFalse);
      expect(ApiService.baseUrl, ApiService.defaultBaseUrl);
    });

    test('the default carries no trailing slash either', () {
      expect(ApiService.defaultBaseUrl.endsWith('/'), isFalse);
    });
  });

  group('mediaUrl', () {
    test('passes an absolute URL through untouched', () async {
      await ApiService.setBaseUrl('https://example.test/inspection/api');
      // What the API actually sends: absolute_photo_url() builds these with
      // build_absolute_uri('/media/<name>').
      const ref = 'https://example.test/media/inspections/li/abc.jpg';
      expect(LineInspectionApi.mediaUrl(ref), ref);
    });

    test('passes an absolute http URL through untouched', () async {
      await ApiService.setBaseUrl('http://10.0.0.5:8000/inspection/api');
      const ref = 'http://10.0.0.5:8000/media/inspections/li/abc.jpg';
      expect(LineInspectionApi.mediaUrl(ref), ref);
    });

    test('resolves a bare storage path against the host root, not the API path',
        () async {
      await ApiService.setBaseUrl('https://example.test/inspection/api');
      // Media is served from /media/ at the root — NOT under /inspection/.
      expect(LineInspectionApi.mediaUrl('inspections/li/abc.jpg'),
          'https://example.test/media/inspections/li/abc.jpg');
    });

    test('keeps a non-default port when resolving a bare path', () async {
      await ApiService.setBaseUrl('http://192.168.137.1:8000/inspection/api');
      expect(LineInspectionApi.mediaUrl('inspections/li/abc.jpg'),
          'http://192.168.137.1:8000/media/inspections/li/abc.jpg');
    });

    test('accepts a leading slash and an already-present media/ prefix',
        () async {
      await ApiService.setBaseUrl('https://example.test/inspection/api');
      const want = 'https://example.test/media/inspections/li/abc.jpg';
      expect(LineInspectionApi.mediaUrl('/media/inspections/li/abc.jpg'), want);
      expect(LineInspectionApi.mediaUrl('media/inspections/li/abc.jpg'), want);
      expect(LineInspectionApi.mediaUrl('/inspections/li/abc.jpg'), want);
    });

    test('never nests one URL inside another', () async {
      await ApiService.setBaseUrl('https://example.test/inspection/api');
      final out = LineInspectionApi
          .mediaUrl('https://example.test/media/inspections/li/abc.jpg');
      // The old implementation produced
      // https://example.test/inspection/media/https://example.test/media/...
      expect(out.indexOf('https://'), out.lastIndexOf('https://'));
      expect(out.contains('/inspection/media/'), isFalse);
    });

    test('an empty reference stays empty rather than becoming a bare host',
        () async {
      await ApiService.setBaseUrl('https://example.test/inspection/api');
      expect(LineInspectionApi.mediaUrl(''), '');
      expect(LineInspectionApi.mediaUrl('   '), '');
    });
  });
}
