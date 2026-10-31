import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/services/youtube_engine/youtube_explode_engine.dart';
import 'package:spotube/services/sourced_track/source_tester.dart';
import 'package:spotube/services/sourced_track/ytdlp_backup.dart';

Future<String> oldCheck(String url) async {
  try {
    final r = await Dio().get<ResponseBody>(url, options: Options(
        responseType: ResponseType.stream, headers: {"Range": "bytes=0-1023"},
        validateStatus: (s) => s != null));
    return 'HTTP ${r.statusCode}';
  } catch (e) { return 'ERR $e'; }
}

void main() {
  const songs = ['Song for Isabelle Pierce The Veil', 'Omen The Prodigy', 'Death Grip Bad Omens', 'Machinehead Sleeping With Sirens'];
  test('v5: tester rejects explode URLs that 403 in proxy; yt-dlp URLs pass', () async {
    final urls = <String>[];
    for (final s in songs) {
      final c = (await YtDlpBackup.search(s, n: 1)).first;
      print('== $s -> ${c.id} ${c.title}');
      try {
        final m = await YouTubeExplodeEngine().getStreamManifest(c.id);
        final u = m.audioOnly.first.url.toString();
        print('  built-in: old 1KB check=${await oldCheck(u)} | new proxy-style check=${await SourceTester.verify(u) ?? "OK"}');
      } catch (e) { print('  built-in ERR ${e.toString().split("\n").first}'); }
      final g = await YtDlpBackup.streamUrl(c.id);
      final v = await SourceTester.verify(g);
      print('  yt-dlp:   new proxy-style check=${v ?? "OK"}');
      expect(v, isNull);
      urls.add(g);
    }
    File('/tmp/jw_ytdlp_urls.txt').writeAsStringSync(urls.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 8)));
}
