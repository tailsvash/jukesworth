// Jukesworth: source tester / fallback log.
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:spotube/services/kv_store/kv_store.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' show YoutubeApiClient;

class SourceTesterEntry {
  final DateTime time;
  final String track;
  final String message;
  final bool ok;
  SourceTesterEntry(this.track, this.message, this.ok) : time = DateTime.now();

  @override
  String toString() =>
      "${time.toIso8601String()} [${ok ? "OK" : "FAIL"}] $track :: $message";
}

enum TesterState { idle, checking, verified, backup, ytdlp, failed }

class SourceTester {
  /// State of the most recent stream check.
  static final state = ValueNotifier<TesterState>(TesterState.idle);
  static final entries = ValueNotifier<List<SourceTesterEntry>>([]);

  /// Last user-facing notice (shown as a small banner in the player UI).
  static final notice = ValueNotifier<String?>(null);

  static String get logFilePath {
    if (Platform.isAndroid || Platform.isIOS) {
      return join(Directory.systemTemp.path, "jukesworth", "source_tester.log");
    }
    final xdg = Platform.environment["XDG_STATE_HOME"];
    final home = Platform.environment["HOME"] ?? ".";
    final base = (xdg != null && xdg.isNotEmpty)
        ? xdg
        : join(home, ".local", "state");
    return join(base, "jukesworth", "source_tester.log");
  }

  static void log(String track, String message, {bool ok = false}) {
    final e = SourceTesterEntry(track, message, ok);
    final list = [e, ...entries.value];
    entries.value = list.length > 300 ? list.sublist(0, 300) : list;
    if (!ok) notice.value = "$track: $message";
    try {
      final f = File(logFilePath);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync("$e\n", mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  /// "Prefer yt-dlp" setting (default ON). The built-in youtube_explode
  /// URLs in 5.1.2 get 403 from googlevideo after the first few KB.
  static bool get preferYtDlp {
    try {
      return KVStoreService.sharedPreferences.getBool("jw_prefer_ytdlp") ?? true;
    } catch (_) {
      return true;
    }
  }

  static set preferYtDlp(bool v) {
    KVStoreService.sharedPreferences.setBool("jw_prefer_ytdlp", v);
  }

  static final _proxyUserAgents = [
    YoutubeApiClient.ios,
    YoutubeApiClient.android,
    YoutubeApiClient.mweb,
    YoutubeApiClient.safari,
  ].map((c) => c.payload["context"]["client"]["userAgent"] as String?).toList();

  /// Checks [url] EXACTLY the way the local stream proxy (routes/playback.dart)
  /// will fetch it: a fresh Dio(), the same random user-agent set, host header,
  /// open-ended Range like mpv sends, and actually reads [minBytes] of audio.
  /// (v1-v4 only fetched 1 KB, which googlevideo serves even for URLs it then
  /// 403s, so broken URLs "passed".)
  static Future<String?> verify(String? url, {int minBytes = 262144}) async {
    if (url == null || url.isEmpty) return "no stream URL for chosen quality";
    final dio = Dio();
    try {
      final ua = _proxyUserAgents[Random().nextInt(_proxyUserAgents.length)];
      final res = await dio.get<ResponseBody>(
        url,
        options: Options(
          headers: {
            "range": "bytes=0-",
            "user-agent": ua,
            "Cache-Control": "max-age=3600",
            "Connection": "keep-alive",
            "host": Uri.parse(url).host,
          },
          responseType: ResponseType.stream,
          receiveTimeout: const Duration(seconds: 12),
          validateStatus: (s) => s != null,
        ),
      ).timeout(const Duration(seconds: 15));
      final code = res.statusCode ?? 0;
      if (code >= 400) {
        try { await res.data?.stream.drain().timeout(const Duration(seconds: 2)); } catch (_) {}
        return "HTTP $code from stream (proxy-style request)";
      }
      var got = 0;
      final total = int.tryParse(res.headers.value("content-length") ?? "") ?? -1;
      final need = total > 0 && total < minBytes ? total : minBytes;
      await for (final chunk in res.data!.stream.timeout(const Duration(seconds: 12))) {
        got += chunk.length;
        if (got >= need) break;
      }
      if (got < need) return "stream ended early ($got bytes)";
      return null;
    } catch (e) {
      if (e is DioException && e.response != null) {
        return "HTTP ${e.response!.statusCode} from stream (proxy-style request)";
      }
      return "stream check failed: ${e.toString().split('\n').first}";
    } finally {
      dio.close(force: true);
    }
  }
}
