// Jukesworth: custom background images.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart' as m;
import 'package:path/path.dart' as p;
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/services/kv_store/kv_store.dart';
import 'package:spotube/services/audio_player/audio_player.dart';
import 'package:spotube/services/sourced_track/source_tester.dart';
import 'package:spotube/services/sourced_track/ytdlp_backup.dart';

const _imageExt = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"};

class JukesBackground extends ChangeNotifier {
  JukesBackground._();
  static final instance = JukesBackground._();

  bool enabled = false;
  String? path; // file or folder
  double dim = 0.55; // 0 = image fully visible, 1 = app fully opaque
  double blur = 6;
  int cycleMinutes = 0; // 0 = off
  bool shuffle = true;
  File? current;
  Timer? _timer;
  int _index = 0;

  bool get isFolder => path != null && FileSystemEntity.isDirectorySync(path!);
  bool get active => enabled && current != null;

  void load() {
    try {
      final sp = KVStoreService.sharedPreferences;
      enabled = sp.getBool("jw_bg_enabled") ?? false;
      path = sp.getString("jw_bg_path");
      dim = sp.getDouble("jw_bg_dim") ?? dim;
      blur = sp.getDouble("jw_bg_blur") ?? blur;
      cycleMinutes = sp.getInt("jw_bg_cycle") ?? 0;
      shuffle = sp.getBool("jw_bg_shuffle") ?? true;
    } catch (_) {}
    _resolve();
  }

  void _save() {
    final sp = KVStoreService.sharedPreferences;
    sp.setBool("jw_bg_enabled", enabled);
    if (path != null) sp.setString("jw_bg_path", path!);
    sp.setDouble("jw_bg_dim", dim);
    sp.setDouble("jw_bg_blur", blur);
    sp.setInt("jw_bg_cycle", cycleMinutes);
    sp.setBool("jw_bg_shuffle", shuffle);
  }

  List<File> _folderImages() {
    try {
      return Directory(path!)
          .listSync()
          .whereType<File>()
          .where((f) => _imageExt.contains(p.extension(f.path).toLowerCase()))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
    } catch (_) {
      return [];
    }
  }

  void _resolve({bool advance = false}) {
    _timer?.cancel();
    current = null;
    if (path == null) return notifyListeners();
    if (isFolder) {
      final imgs = _folderImages();
      if (imgs.isNotEmpty) {
        if (advance) {
          _index = shuffle && imgs.length > 1
              ? (_index + 1 + Random().nextInt(imgs.length - 1)) % imgs.length
              : (_index + 1) % imgs.length;
        }
        _index = _index % imgs.length;
        current = imgs[_index];
        if (enabled && cycleMinutes > 0) {
          _timer = Timer(Duration(minutes: cycleMinutes),
              () => _resolve(advance: true));
        }
      }
    } else if (File(path!).existsSync()) {
      current = File(path!);
    }
    notifyListeners();
  }

  void next() => _resolve(advance: true);

  void update({
    bool? enabled,
    String? path,
    double? dim,
    double? blur,
    int? cycleMinutes,
    bool? shuffle,
  }) {
    final reresolve = path != null || enabled != null || cycleMinutes != null;
    if (enabled != null) this.enabled = enabled;
    if (path != null) {
      this.path = path;
      _index = 0;
    }
    if (dim != null) this.dim = dim;
    if (blur != null) this.blur = blur;
    if (cycleMinutes != null) this.cycleMinutes = cycleMinutes;
    if (shuffle != null) this.shuffle = shuffle;
    _save();
    if (reresolve) {
      _resolve();
    } else {
      notifyListeners();
    }
  }
}

/// Paints the chosen image behind the whole app.
class JukesBackgroundLayer extends StatelessWidget {
  final Widget child;
  const JukesBackgroundLayer({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final bg = JukesBackground.instance;
    return ListenableBuilder(
      listenable: bg,
      builder: (context, _) {
        if (!bg.active) return child;
        Widget img = Image.file(
          bg.current!,
          key: ValueKey(bg.current!.path),
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        );
        if (bg.blur > 0) {
          img = ImageFiltered(
            imageFilter: ui.ImageFilter.blur(
                sigmaX: bg.blur, sigmaY: bg.blur, tileMode: TileMode.clamp),
            child: img,
          );
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 800),
              child: img,
            ),
            child,
          ],
        );
      },
    );
  }
}

/// Small notice banner for source-tester problems.
class SourceTesterNotice extends StatelessWidget {
  const SourceTesterNotice({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: SourceTester.notice,
      builder: (context, msg, _) {
        if (msg == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Row(
            children: [
              const Icon(m.Icons.info_outline, size: 14),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  "Source tester: $msg",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ).xSmall(),
              ),
              IconButton.ghost(
                size: ButtonSize.xSmall,
                icon: const Icon(m.Icons.close, size: 14),
                onPressed: () => SourceTester.notice.value = null,
              ),
            ],
          ),
        );
      },
    );
  }
}

class SettingsJukesworthSection extends StatelessWidget {
  const SettingsJukesworthSection({super.key});

  @override
  Widget build(BuildContext context) {
    final bg = JukesBackground.instance;
    return ListenableBuilder(
      listenable: bg,
      builder: (context, _) {
        return Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Jukesworth").h4(),
              const SizedBox(height: 8),
              m.ListTile(
                leading: const Icon(m.Icons.wallpaper),
                title: const Text("Custom background"),
                subtitle: Text(bg.path == null
                    ? "No image chosen"
                    : "${bg.isFolder ? "Folder" : "Image"}: ${bg.path}"),
                trailing: Switch(
                  value: bg.enabled,
                  onChanged: (v) => bg.update(enabled: v),
                ),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  Button.secondary(
                    onPressed: () async {
                      final f = await openFile(acceptedTypeGroups: const [
                        XTypeGroup(
                          label: "Images",
                          extensions: [
                            "jpg", "jpeg", "png", "webp", "gif", "bmp"
                          ],
                        ),
                      ]);
                      if (f != null) bg.update(path: f.path, enabled: true);
                    },
                    child: const Text("Choose image"),
                  ),
                  Button.secondary(
                    onPressed: () async {
                      final d = await getDirectoryPath();
                      if (d != null) bg.update(path: d, enabled: true);
                    },
                    child: const Text("Choose folder"),
                  ),
                  if (bg.isFolder)
                    Button.outline(
                      onPressed: bg.next,
                      child: const Text("Next image"),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text("Dim (readability): ${(bg.dim * 100).round()}%").small(),
              m.Slider(
                value: bg.dim,
                min: 0,
                max: 0.95,
                onChanged: (v) => bg.update(dim: v),
              ),
              Text("Blur: ${bg.blur.toStringAsFixed(0)}").small(),
              m.Slider(
                value: bg.blur,
                min: 0,
                max: 30,
                onChanged: (v) => bg.update(blur: v),
              ),
              if (bg.isFolder) ...[
                Text(bg.cycleMinutes == 0
                        ? "Cycle folder: off"
                        : "Cycle folder every ${bg.cycleMinutes} min")
                    .small(),
                m.Slider(
                  value: bg.cycleMinutes.toDouble(),
                  min: 0,
                  max: 60,
                  divisions: 12,
                  onChanged: (v) => bg.update(cycleMinutes: v.round()),
                ),
                m.CheckboxListTile(
                  value: bg.shuffle,
                  title: const Text("Shuffle folder"),
                  onChanged: (v) => bg.update(shuffle: v ?? true),
                ),
              ],
              const Divider(),
              StatefulBuilder(
                builder: (context, setSt) => m.SwitchListTile(
                  value: SourceTester.preferYtDlp,
                  title: const Text("Prefer yt-dlp engine"),
                  subtitle: Text(YtDlpBackup.available
                      ? "Using ${YtDlpBackup.executable}. Built-in engine is the fallback."
                      : "yt-dlp not found on PATH (install it to use this)"),
                  onChanged: (v) {
                    SourceTester.preferYtDlp = v;
                    setSt(() {});
                  },
                ),
              ),
              m.ListTile(
                leading: const Icon(m.Icons.fact_check_outlined),
                title: const Text("Source tester log"),
                subtitle: Text(SourceTester.logFilePath),
                trailing: Button.outline(
                  onPressed: () => showDialog(
                    context: context,
                    builder: (_) => const _SourceLogDialog(),
                  ),
                  child: const Text("View"),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SourceLogDialog extends StatelessWidget {
  const _SourceLogDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("Source tester log"),
      content: SizedBox(
        width: 600,
        height: 400,
        child: ValueListenableBuilder<List<SourceTesterEntry>>(
          valueListenable: SourceTester.entries,
          builder: (context, entries, _) {
            String text = entries.map((e) => e.toString()).join("\n");
            if (text.isEmpty) {
              try {
                final f = File(SourceTester.logFilePath);
                if (f.existsSync()) {
                  final lines = f.readAsLinesSync();
                  text = lines.reversed.take(300).join("\n");
                }
              } catch (_) {}
            }
            return SingleChildScrollView(
              child: SelectableText(
                  text.isEmpty ? "No problems logged yet." : text),
            );
          },
        ),
      ),
      actions: [
        Button.outline(
          onPressed: () {
            SourceTester.entries.value = [];
            try {
              File(SourceTester.logFilePath).writeAsStringSync("");
            } catch (_) {}
          },
          child: const Text("Clear"),
        ),
        Button.primary(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text("Close"),
        ),
      ],
    );
  }
}


/// Small coloured dot: red = stopped/failed, blue = playing/checking,
/// green = current stream verified.
class SourceTesterDot extends StatelessWidget {
  const SourceTesterDot({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: audioPlayer.playingStream,
      initialData: audioPlayer.isPlaying,
      builder: (context, snap) {
        final playing = snap.data ?? false;
        return ValueListenableBuilder<TesterState>(
          valueListenable: SourceTester.state,
          builder: (context, st, _) {
            late final Color color;
            late final String text;
            switch (st) {
              case TesterState.checking:
                color = const Color(0xFF2196F3);
                text = "Checking\u2026";
              case TesterState.failed:
                color = const Color(0xFFE53935);
                text = "Failed / skipped: ${SourceTester.notice.value ?? "no working match"}";
              case TesterState.verified:
                color = playing ? const Color(0xFF43A047) : const Color(0xFFE53935);
                text = playing ? "Stream verified" : "Stopped (last stream verified)";
              case TesterState.backup:
                color = playing ? const Color(0xFF43A047) : const Color(0xFFE53935);
                text = playing ? "Failed: using backup match" : "Stopped (backup match)";
              case TesterState.ytdlp:
                color = playing ? const Color(0xFF43A047) : const Color(0xFFE53935);
                text = playing ? "Playing via yt-dlp backup" : "Stopped (yt-dlp backup)";
              case TesterState.idle:
                color = playing ? const Color(0xFF2196F3) : const Color(0xFFE53935);
                text = playing ? "Playing (not checked yet)" : "Stopped";
            }
            return Tooltip(
              tooltip: TooltipContainer(child: Text("Source tester: $text")).call,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: color.withValues(alpha: .6), blurRadius: 4)],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
