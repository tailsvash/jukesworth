// Jukesworth: yt-dlp backup resolver (used when the YouTube plugin fails).
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class YtDlpCandidate {
  final String id;
  final String title;
  final String uploader;
  final Duration duration;
  YtDlpCandidate(this.id, this.title, this.uploader, this.duration);
}

class YtDlpBackup {
  static String? _cached;
  static bool _looked = false;

  /// Public alias used at startup.
  static String? findExecutable() => executable;

  /// Finds yt-dlp next to the app, on PATH (plus common locations). null if not installed.
  static String? get executable {
    if (_looked) return _cached;
    _looked = true;
    // Jukesworth: yt-dlp is a desktop program; phones use the built-in sources.
    if (!(Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
      return null;
    }
    final win = Platform.isWindows;
    final name = win ? "yt-dlp.exe" : "yt-dlp";
    final dirs = <String>[
      // bundled next to the app (Windows release zip ships yt-dlp.exe here)
      p.dirname(Platform.resolvedExecutable),
      ...(Platform.environment["PATH"] ?? "").split(win ? ";" : ":"),
      if (!win) ...[
        "/usr/bin",
        "/usr/local/bin",
        p.join(Platform.environment["HOME"] ?? "", ".local", "bin"),
      ],
    ];
    for (final d in dirs) {
      if (d.isEmpty) continue;
      final f = File(p.join(d, name));
      if (f.existsSync()) return _cached = f.path;
    }
    return null;
  }

  static bool get available => executable != null;

  static Future<ProcessResult> _run(List<String> args, Duration timeout) async {
    final proc = await Process.start(executable!, args);
    final out = proc.stdout.transform(utf8.decoder).join();
    final err = proc.stderr.transform(utf8.decoder).join();
    final code = await proc.exitCode.timeout(timeout, onTimeout: () {
      proc.kill(ProcessSignal.sigkill);
      return -999;
    });
    if (code == -999) throw Exception("yt-dlp timed out after ${timeout.inSeconds}s");
    return ProcessResult(proc.pid, code, await out, await err);
  }

  static String _firstErr(Object e) {
    final s = e.toString().trim().split("\n").where((l) => l.trim().isNotEmpty);
    return s.isEmpty ? "unknown error" : s.last;
  }

  /// `yt-dlp "ytsearch5:<query>" --dump-json --flat-playlist`
  static Future<List<YtDlpCandidate>> search(String query, {int n = 5}) async {
    final r = await _run(
      ["ytsearch$n:$query", "--dump-json", "--flat-playlist", "--no-warnings"],
      const Duration(seconds: 40),
    );
    if (r.exitCode != 0) {
      throw Exception("yt-dlp search exit ${r.exitCode}: ${_firstErr(r.stderr)}");
    }
    final list = <YtDlpCandidate>[];
    for (final line in (r.stdout as String).split("\n")) {
      if (line.trim().isEmpty) continue;
      try {
        final j = jsonDecode(line) as Map<String, dynamic>;
        final id = j["id"] as String?;
        if (id == null) continue;
        list.add(YtDlpCandidate(
          id,
          (j["title"] ?? "") as String,
          (j["channel"] ?? j["uploader"] ?? "") as String,
          Duration(seconds: ((j["duration"] ?? 0) as num).round()),
        ));
      } catch (_) {}
    }
    return list;
  }

  /// `yt-dlp -f bestaudio -g <id>`
  static Future<String> streamUrl(String id) async {
    final r = await _run(
      ["-f", "bestaudio", "-g", "--no-warnings", "--", id],
      const Duration(seconds: 45),
    );
    final url = (r.stdout as String)
        .split("\n")
        .map((l) => l.trim())
        .firstWhere((l) => l.startsWith("http"), orElse: () => "");
    if (r.exitCode != 0 || url.isEmpty) {
      throw Exception("yt-dlp -g exit ${r.exitCode}: ${_firstErr(r.stderr)}");
    }
    return url;
  }

  /// Guess container from googlevideo mime param.
  static String containerOf(String url) {
    final mime = Uri.tryParse(url)?.queryParameters["mime"] ?? "";
    if (mime.contains("webm")) return "weba";
    if (mime.contains("mp4")) return "m4a";
    return "m4a";
  }
}
