import 'dart:io';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotube/models/database/database.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/models/playback/track_sources.dart';
import 'package:spotube/provider/database/database.dart';
import 'package:spotube/provider/metadata_plugin/audio_source/quality_presets.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';
import 'package:spotube/services/dio/dio.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/metadata/errors/exceptions.dart';

import 'package:spotube/services/sourced_track/exceptions.dart';
import 'package:spotube/services/sourced_track/source_tester.dart';
import 'package:spotube/services/sourced_track/ytdlp_backup.dart';
import 'package:spotube/utils/service_utils.dart';

final officialMusicRegex = RegExp(
  r"official\s(video|audio|music\svideo|lyric\svideo|visualizer)",
  caseSensitive: false,
);

class SourcedTrack extends BasicSourcedTrack {
  final Ref ref;

  SourcedTrack({
    required this.ref,
    required super.info,
    required super.query,
    required super.source,
    required super.siblings,
    required super.sources,
  });

  static Future<SourcedTrack> fetchFromTrack({
    required SpotubeFullTrackObject query,
    required Ref ref,
  }) async {
    final audioSource = await ref.read(audioSourcePluginProvider.future);
    final audioSourceConfig = await ref.read(metadataPluginsProvider
        .selectAsync((data) => data.defaultAudioSourcePluginConfig));
    if (audioSource == null || audioSourceConfig == null) {
      SourceTester.log(query.name, "no default audio source plugin set");
      throw MetadataPluginException.noDefaultAudioSourcePlugin();
    }

    final database = ref.read(databaseProvider);
    final cachedSource = await (database.select(database.sourceMatchTable)
          ..where((s) =>
              s.trackId.equals(query.id) &
              s.sourceType.equals(audioSourceConfig.slug))
          ..limit(1)
          ..orderBy([
            (s) =>
                OrderingTerm(expression: s.createdAt, mode: OrderingMode.desc),
          ]))
        .get()
        .then((s) => s.firstOrNull);

    // Jukesworth source tester: build an ordered candidate list
    // (cached match first, then search results) and pick the first one
    // whose stream actually responds.
    final candidates = <SpotubeAudioSourceMatchObject>[];
    if (cachedSource != null) {
      try {
        candidates.add(SpotubeAudioSourceMatchObject.fromJson(
          jsonDecode(cachedSource.sourceInfo),
        ));
      } catch (e) {
        SourceTester.log(query.name, "cached match unreadable: $e");
      }
    }

    List<SpotubeAudioSourceMatchObject>? searched;
    Future<void> addSearched() async {
      if (searched != null) return;
      for (var attempt = 1; attempt <= 3; attempt++) {
        try {
          searched = await fetchSiblings(ref: ref, query: query)
              .timeout(const Duration(seconds: 30));
          if (searched!.isNotEmpty) break;
          SourceTester.log(query.name, "search attempt $attempt returned 0 matches");
        } catch (e) {
          searched = [];
          SourceTester.log(query.name,
              "search attempt $attempt/3 failed: ${e.toString().split('\n').first}");
        }
        if (attempt < 3) {
          await Future.delayed(Duration(milliseconds: 800 * attempt));
        }
      }
      for (final s in searched!) {
        if (candidates.none((c) => c.id == s.id)) candidates.add(s);
      }
    }

    if (candidates.isEmpty) await addSearched();
    SourceTester.state.value = TesterState.checking;
    if (candidates.isEmpty) {
      SourceTester.log(query.name,
          "no matches found on ${audioSourceConfig.slug}${YtDlpBackup.available ? ", trying yt-dlp" : ""}");
      final y = await _ytDlpFallback(ref: ref, query: query, tried: const [],
          source: audioSourceConfig.slug);
      if (y != null) return y;
      SourceTester.state.value = TesterState.failed;
      SourceTester.log(query.name, "SKIP: no source could play this track");
      throw TrackNotFoundError(query);
    }

    SourcedTrack? fallbackUnverified;
    const maxTries = 8;
    for (var i = 0; i < candidates.length && i < maxTries; i++) {
      final item = candidates[i];
      try {
        List<SpotubeAudioSourceStreamObject>? viaYtDlp;
        if (SourceTester.preferYtDlp &&
            YtDlpBackup.available &&
            _ytIdRe.hasMatch(item.id)) {
          try {
            viaYtDlp = ytDlpSources(ref, await YtDlpBackup.streamUrl(item.id));
          } catch (e) {
            SourceTester.log(query.name,
                "yt-dlp for '${item.title}' failed, trying built-in engine: ${e.toString().split('\n').first}");
          }
        }
        final manifest = viaYtDlp ??
            await audioSource.audioSource
                .streams(item)
                .timeout(const Duration(seconds: 50));
        final track = SourcedTrack(
          ref: ref,
          siblings: candidates.where((c) => c.id != item.id).toList(),
          sources: manifest,
          info: item,
          query: query,
          source: audioSourceConfig.slug,
        );
        if (manifest.isEmpty) {
          SourceTester.log(query.name, "match '${item.title}' returned no streams");
        } else {
          fallbackUnverified ??= track;
          final problem = await SourceTester.verify(track.url);
          if (problem == null) {
            if (i == 0) {
              SourceTester.log(query.name,
                  "verified '${item.title}'${cachedSource != null ? " (cached match)" : ""}${viaYtDlp != null ? " via yt-dlp" : " via built-in engine"}",
                  ok: true);
            }
            if (i > 0) {
              SourceTester.log(query.name,
                  "fell back to match #${i + 1} '${item.title}'", ok: true);
              SourceTester.notice.value =
                  "${query.name}: used backup match #${i + 1}";
            }
            if (cachedSource == null || i > 0) {
              await (database.sourceMatchTable.delete()
                    ..where((t) =>
                        t.trackId.equals(query.id) &
                        t.sourceType.equals(audioSourceConfig.slug)))
                  .go();
              await database.into(database.sourceMatchTable).insert(
                    SourceMatchTableCompanion.insert(
                      trackId: query.id,
                      sourceInfo: Value(jsonEncode(item)),
                      sourceType: audioSourceConfig.slug,
                      createdAt: Value(DateTime.now()),
                    ),
                    mode: InsertMode.replace,
                  );
            }
            SourceTester.state.value = viaYtDlp != null
                ? TesterState.ytdlp
                : i > 0
                    ? TesterState.backup
                    : TesterState.verified;
            AppLogger.log.i("${query.name}: ${track.url}");
            return track;
          }
          SourceTester.log(query.name, "match '${item.title}': $problem");
        }
      } catch (e) {
        SourceTester.log(query.name,
            "match '${item.title}' failed: ${e.toString().split('\n').first}");
      }
      // ran out of cached candidates -> pull in search results
      if (i == candidates.length - 1) await addSearched();
    }

    final y = await _ytDlpFallback(
      ref: ref,
      query: query,
      tried: candidates,
      source: audioSourceConfig.slug,
    );
    if (y != null) return y;

    if (fallbackUnverified != null) {
      SourceTester.log(query.name,
          "no match passed the stream test${YtDlpBackup.available ? " (yt-dlp too)" : ""}; trying first one anyway");
      SourceTester.state.value = TesterState.failed;
      return fallbackUnverified;
    }
    SourceTester.log(query.name, "SKIP: all matches failed (plugin + yt-dlp)");
    SourceTester.state.value = TesterState.failed;
    throw TrackNotFoundError(query);
  }

  static final _ytIdRe = RegExp(r'^[A-Za-z0-9_-]{11}$');

  /// One stream entry per preset container so quality selection finds it.
  static List<SpotubeAudioSourceStreamObject> ytDlpSources(Ref ref, String url) {
    final presets = ref.read(audioSourcePresetsProvider).presets;
    final names = {YtDlpBackup.containerOf(url), ...presets.map((p) => p.name)};
    return names
        .map((n) => SpotubeAudioSourceStreamObject(
              url: url,
              container: n,
              type: SpotubeMediaCompressionType.lossy,
              bitrate: 160000,
            ))
        .toList();
  }

  /// Jukesworth: yt-dlp backup. Tries the already-known YouTube ids first,
  /// then `ytsearch5:<artist> <title>`.
  static Future<SourcedTrack?> _ytDlpFallback({
    required Ref ref,
    required SpotubeFullTrackObject query,
    required List<SpotubeAudioSourceMatchObject> tried,
    required String source,
  }) async {
    if (!YtDlpBackup.available) {
      if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
        SourceTester.log(query.name, "yt-dlp backup not installed (not on PATH)");
      }
      return null;
    }
    SourceTester.state.value = TesterState.checking;
    final cands = <SpotubeAudioSourceMatchObject>[
      ...tried.where((t) => _ytIdRe.hasMatch(t.id)).take(3),
    ];
    try {
      final q = "${query.artists.map((a) => a.name).join(" ")} ${query.name}";
      final found = await YtDlpBackup.search(q);
      for (final f in found) {
        if (cands.none((c) => c.id == f.id)) {
          cands.add(SpotubeAudioSourceMatchObject(
            id: f.id,
            title: f.title,
            artists: [f.uploader],
            duration: f.duration,
            externalUri: "https://www.youtube.com/watch?v=${f.id}",
          ));
        }
      }
    } catch (e) {
      SourceTester.log(query.name, "yt-dlp search failed: ${e.toString().split('\n').first}");
    }
    for (final c in cands.take(6)) {
      try {
        final url = await YtDlpBackup.streamUrl(c.id);
        final problem = await SourceTester.verify(url);
        if (problem != null) {
          SourceTester.log(query.name, "yt-dlp '${c.title}': $problem");
          continue;
        }
        final sources = ytDlpSources(ref, url);
        SourceTester.log(query.name, "playing via yt-dlp backup '${c.title}' (${c.id})", ok: true);
        SourceTester.notice.value = "${query.name}: playing via yt-dlp backup";
        SourceTester.state.value = TesterState.ytdlp;
        return SourcedTrack(
          ref: ref,
          info: c,
          query: query,
          source: source,
          siblings: cands.where((x) => x.id != c.id).toList(),
          sources: sources,
        );
      } catch (e) {
        SourceTester.log(query.name, "yt-dlp '${c.title}' failed: ${e.toString().split('\n').first}");
      }
    }
    return null;
  }

  static List<SpotubeAudioSourceMatchObject> rankResults(
    List<SpotubeAudioSourceMatchObject> results,
    SpotubeFullTrackObject track,
  ) {
    return results
        .map((sibling) {
          int score = 0;

          for (final artist in track.artists) {
            final isSameChannelArtist =
                sibling.artists.any((a) => a.toLowerCase() == artist.name);

            if (isSameChannelArtist) {
              score += 1;
            }

            final titleContainsArtist =
                sibling.title.toLowerCase().contains(artist.name.toLowerCase());

            if (titleContainsArtist) {
              score += 1;
            }
          }

          final titleContainsTrackName =
              sibling.title.toLowerCase().contains(track.name.toLowerCase());

          final hasOfficialFlag =
              officialMusicRegex.hasMatch(sibling.title.toLowerCase());

          if (titleContainsTrackName) {
            score += 3;
          }

          if (hasOfficialFlag) {
            score += 1;
          }

          if (hasOfficialFlag && titleContainsTrackName) {
            score += 2;
          }

          return (sibling: sibling, score: score);
        })
        .sorted((a, b) => b.score.compareTo(a.score))
        .map((e) => e.sibling)
        .toList();
  }

  static Future<List<SpotubeAudioSourceMatchObject>> fetchSiblings({
    required SpotubeFullTrackObject query,
    required Ref ref,
  }) async {
    final audioSource = await ref.read(audioSourcePluginProvider.future);

    if (audioSource == null) {
      throw MetadataPluginException.noDefaultAudioSourcePlugin();
    }

    final videoResults = <SpotubeAudioSourceMatchObject>[];

    final searchResults = await audioSource.audioSource.matches(query);

    if (ServiceUtils.onlyContainsEnglish(query.name)) {
      videoResults.addAll(searchResults);
    } else {
      videoResults.addAll(rankResults(searchResults, query));
    }

    return videoResults.toSet().toList();
  }

  Future<SourcedTrack> copyWithSibling() async {
    if (siblings.isNotEmpty) {
      return this;
    }
    final fetchedSiblings = await fetchSiblings(ref: ref, query: query);

    return SourcedTrack(
      ref: ref,
      siblings: fetchedSiblings.where((s) => s.id != info.id).toList(),
      source: source,
      sources: sources,
      info: info,
      query: query,
    );
  }

  Future<SourcedTrack?> swapWithSibling(
    SpotubeAudioSourceMatchObject sibling,
  ) async {
    if (sibling.id == info.id) {
      return null;
    }

    final audioSource = await ref.read(audioSourcePluginProvider.future);
    final audioSourceConfig = await ref.read(metadataPluginsProvider
        .selectAsync((data) => data.defaultAudioSourcePluginConfig));
    if (audioSource == null || audioSourceConfig == null) {
      throw MetadataPluginException.noDefaultAudioSourcePlugin();
    }

    // a sibling source that was fetched from the search results
    final isStepSibling = siblings.none((s) => s.id == sibling.id);

    final newSourceInfo = isStepSibling
        ? sibling
        : siblings.firstWhere((s) => s.id == sibling.id);

    final newSiblings = siblings.where((s) => s.id != sibling.id).toList()
      ..insert(0, info);

    SourceTester.log(query.name, "switching to sibling '${newSourceInfo.title}'", ok: true);
    final List<SpotubeAudioSourceStreamObject> manifest;
    try {
      manifest = await audioSource.audioSource
          .streams(newSourceInfo)
          .timeout(const Duration(seconds: 50));
    } catch (e) {
      SourceTester.log(query.name,
          "sibling '${newSourceInfo.title}' failed: ${e.toString().split('\n').first}");
      rethrow;
    }

    final database = ref.read(databaseProvider);

    // Delete the old Entry
    await (database.sourceMatchTable.delete()
          ..where(
            (table) =>
                table.trackId.equals(query.id) &
                table.sourceType.equals(audioSourceConfig.slug),
          ))
        .go();

    await database.into(database.sourceMatchTable).insert(
          SourceMatchTableCompanion.insert(
            trackId: query.id,
            sourceInfo: Value(jsonEncode(sibling)),
            sourceType: audioSourceConfig.slug,
            createdAt: Value(DateTime.now()),
          ),
          mode: InsertMode.replace,
        );

    return SourcedTrack(
      ref: ref,
      source: source,
      siblings: newSiblings,
      sources: manifest,
      info: newSourceInfo,
      query: query,
    );
  }

  Future<SourcedTrack?> swapWithSiblingOfIndex(int index) {
    return swapWithSibling(siblings[index]);
  }

  /// Jukesworth: refresh (expired URL etc.) goes through the tester too.
  Future<SourcedTrack> refreshStream() async {
    SourceTester.log(query.name, "stream URL refresh requested (expired/failed URL)");
    SourceTester.state.value = TesterState.checking;
    if (YtDlpBackup.available && SourceTester.preferYtDlp) {
      return fetchFromTrack(query: query, ref: ref);
    }
    try {
      final t = await _refreshStreamInner().timeout(const Duration(seconds: 60));
      final problem = await SourceTester.verify(t.url);
      if (problem == null) {
        SourceTester.log(query.name, "refreshed URL verified", ok: true);
        SourceTester.state.value = TesterState.verified;
        return t;
      }
      SourceTester.log(query.name, "refreshed URL bad: $problem; re-resolving");
    } catch (e) {
      SourceTester.log(query.name,
          "refresh failed: ${e.toString().split('\n').first}; re-resolving");
    }
    return fetchFromTrack(query: query, ref: ref);
  }

  Future<SourcedTrack> _refreshStreamInner() async {
    final audioSource = await ref.read(audioSourcePluginProvider.future);
    final audioSourceConfig = await ref.read(metadataPluginsProvider
        .selectAsync((data) => data.defaultAudioSourcePluginConfig));
    if (audioSource == null || audioSourceConfig == null) {
      throw MetadataPluginException.noDefaultAudioSourcePlugin();
    }

    List<SpotubeAudioSourceStreamObject> validStreams = [];

    final stringBuffer = StringBuffer();
    for (final source in sources) {
      final res = await globalDio.head(
        source.url,
        options:
            Options(validateStatus: (status) => status != null && status < 500),
      ).timeout(const Duration(seconds: 12));

      stringBuffer.writeln(
        "[${query.id}] ${res.statusCode} ${source.container} ${source.codec} ${source.bitrate}",
      );

      if (res.statusCode! < 400) {
        validStreams.add(source);
      }
    }

    AppLogger.log.d(stringBuffer.toString());

    if (validStreams.isEmpty) {
      validStreams = await audioSource.audioSource.streams(info);
    }

    final sourcedTrack = SourcedTrack(
      ref: ref,
      siblings: siblings,
      source: source,
      sources: validStreams,
      info: info,
      query: query,
    );

    AppLogger.log.i("Refreshing ${query.name}: ${sourcedTrack.url}");

    return sourcedTrack;
  }

  String? get url {
    final preferences = ref.read(audioSourcePresetsProvider);
    try {
      return getUrlOfQuality(
        preferences.presets[preferences.selectedStreamingContainerIndex],
        preferences.selectedStreamingQualityIndex,
      );
    } catch (e) {
      // Jukesworth: no stream in the preferred container -> use any stream
      SourceTester.log(query.name,
          "no stream in preferred container, using '${sources.firstOrNull?.container}'");
      return sources.firstOrNull?.url;
    }
  }

  /// Returns the URL of the track based on the codec and quality preferences.
  /// If an exact match is not found, it will return the closest match based on
  /// the user's audio quality preference.
  ///
  /// If no sources match the codec, it will return the first or last source
  /// based on the user's audio quality preference.
  SpotubeAudioSourceStreamObject? getStreamOfQuality(
    SpotubeAudioSourceContainerPreset preset,
    int qualityIndex,
  ) {
    if (sources.isEmpty) return null;

    final quality = preset.qualities[qualityIndex];

    final exactMatch = sources.firstWhereOrNull(
      (source) {
        if (source.container != preset.name) return false;

        if (quality case SpotubeAudioLosslessContainerQuality()) {
          return source.sampleRate == quality.sampleRate &&
              source.bitDepth == quality.bitDepth;
        } else {
          return source.bitrate ==
              (quality as SpotubeAudioLossyContainerQuality).bitrate;
        }
      },
    );

    if (exactMatch != null) {
      return exactMatch;
    }

    // Find the preset with closest quality to the supplied quality
    return sources.where((source) {
      return source.container == preset.name;
    }).reduce((prev, curr) {
      if (quality is SpotubeAudioLosslessContainerQuality) {
        final prevDiff = ((prev.sampleRate ?? 0) - quality.sampleRate).abs() +
            ((prev.bitDepth ?? 0) - quality.bitDepth).abs();
        final currDiff = ((curr.sampleRate ?? 0) - quality.sampleRate).abs() +
            ((curr.bitDepth ?? 0) - quality.bitDepth).abs();
        return currDiff < prevDiff ? curr : prev;
      } else {
        final prevDiff = ((prev.bitrate ?? 0) -
                (quality as SpotubeAudioLossyContainerQuality).bitrate)
            .abs();
        final currDiff = ((curr.bitrate ?? 0) - quality.bitrate).abs();
        return currDiff < prevDiff ? curr : prev;
      }
    });
  }

  String? getUrlOfQuality(
    SpotubeAudioSourceContainerPreset preset,
    int qualityIndex,
  ) {
    return getStreamOfQuality(preset, qualityIndex)?.url;
  }

  SpotubeAudioSourceContainerPreset? get qualityPreset {
    final presetState = ref.read(audioSourcePresetsProvider);
    return presetState.presets
        .elementAtOrNull(presetState.selectedStreamingContainerIndex);
  }
}
