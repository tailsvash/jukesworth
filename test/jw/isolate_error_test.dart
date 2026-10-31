import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/services/youtube_engine/youtube_explode_engine.dart';

void main() {
  test('unplayable video returns an error instead of hanging', () async {
    await IsolatedYoutubeExplode.initialize();
    final sw = Stopwatch()..start();
    Object? err;
    try {
      await IsolatedYoutubeExplode.instance.manifest('IzCFHyB6vJI');
    } catch (e) {
      err = e;
    }
    print('result after ${sw.elapsed}: $err');
    expect(err, isNotNull);
    // a normal video still works afterwards (isolate survived)
    final m = await IsolatedYoutubeExplode.instance.manifest('dQw4w9WgXcQ');
    print('normal video audio streams: ${m.audioOnly.length}');
    expect(m.audioOnly, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
