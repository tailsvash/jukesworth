import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

// Mirrors routes/playback.dart streamTrack: forward mpv's headers, override UA/host.
void main() {
  test('mpv plays yt-dlp URLs through a playback.dart-style Dio proxy', () async {
    final urls = File('/tmp/jw_ytdlp_urls.txt').readAsLinesSync();
    final ua = 'com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)';
    var cur = urls.first;
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((req) async {
      final h = <String, dynamic>{};
      req.headers.forEach((k, v) => h[k] = v.join(','));
      final dio = Dio();
      try {
        final res = await dio.get<ResponseBody>(cur, options: Options(
          headers: {...h, 'user-agent': ua, 'Cache-Control': 'max-age=3600',
            'Connection': 'keep-alive', 'host': Uri.parse(cur).host},
          responseType: ResponseType.stream, validateStatus: (s) => s! < 400));
        req.response.statusCode = res.statusCode!;
        res.headers.forEach((k, v) { if (k != 'transfer-encoding') req.response.headers.set(k, v.join(',')); });
        await req.response.addStream(res.data!.stream);
      } on DioException catch (e) {
        print('proxy upstream ${e.response?.statusCode}');
        req.response.statusCode = 500;
      }
      await req.response.close();
    });
    for (final u in urls) {
      cur = u;
      final r = await Process.run('mpv', ['--no-video', '--ao=null', '--length=8',
          '--msg-level=all=warn,ffmpeg=error', '--term-playing-msg=PLAYING',
          'http://127.0.0.1:${server.port}/stream/x']).timeout(const Duration(seconds: 60));
      print('mpv exit=${r.exitCode} ${(r.stdout as String).trim()} ${(r.stderr as String).trim()}');
      expect(r.exitCode, 0);
    }
    await server.close(force: true);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
