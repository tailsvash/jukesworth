import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/services/sourced_track/ytdlp_backup.dart';

void main() {
  test('yt-dlp found on PATH', () {
    print('yt-dlp: ${YtDlpBackup.executable}');
    expect(YtDlpBackup.available, isTrue);
  });
  test('ytsearch5 + -g gives a stream URL', () async {
    final c = await YtDlpBackup.search('Hollywood Undead Lone Wolf Hysteria');
    print('candidates: ${c.map((e) => "${e.id} ${e.title}").join(" | ")}');
    expect(c, isNotEmpty);
    String? url;
    for (final x in c) {
      try { url = await YtDlpBackup.streamUrl(x.id); break; } catch (e) { print('fail ${x.id}: $e'); }
    }
    expect(url, isNotNull); print('url host: ${Uri.parse(url!).host} container ${YtDlpBackup.containerOf(url)}');
    expect(url, startsWith('http'));
  }, timeout: const Timeout(Duration(minutes: 4)));
  test('blocked video errors fast via yt-dlp, no hang', () async {
    Object? err;
    try { await YtDlpBackup.streamUrl('IzCFHyB6vJI'); } catch (e) { err = e; }
    print('IzCFHyB6vJI via yt-dlp: $err');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
