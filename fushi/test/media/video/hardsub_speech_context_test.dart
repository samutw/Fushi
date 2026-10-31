import 'dart:io';
import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/graphic_subtitle_ocr.dart';
import 'package:fushi/src/media/video/player_decoded_subtitle_cues.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// 硬字幕暂停 OCR 制卡的上一句 / 下一句：借文本字幕轨时间的伪字幕流（只借时间、
/// 不借文字）、给邻句补字时挑「最像字幕」的那一行，以及页面 / 控制器 / 设置的接线。
AudioCue _cue(String text, int startMs, int endMs) =>
    buildFrameOcrPseudoCue(text: text, startMs: startMs, endMs: endMs);

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('textCueIndexCoveringPosition', () {
    final List<AudioCue> track = <AudioCue>[
      _cue('Hello.', 1000, 3000),
      _cue('How are you?', 4000, 6000),
    ];

    test('严格覆盖才算；调轴后按播放器轴比', () {
      expect(
        textCueIndexCoveringPosition(cues: track, delayMs: 0, positionMs: 4500),
        1,
      );
      expect(
        textCueIndexCoveringPosition(
          cues: track,
          delayMs: 500,
          positionMs: 3200,
        ),
        0,
      );
    });

    test('句间空档 → -1（不猜最近一句）', () {
      expect(
        textCueIndexCoveringPosition(cues: track, delayMs: 0, positionMs: 3500),
        -1,
      );
    });
  });

  group('buildFrameOcrTimingStream', () {
    final List<AudioCue> track = <AudioCue>[
      for (int i = 0; i < 20; i++)
        _cue('English line $i.', i * 3000, i * 3000 + 2000),
    ];

    test('锚点 = OCR 文字 + 那句的时间；邻句只有时间、文字留空', () {
      final ({AudioCue anchor, List<AudioCue> stream})? built =
          buildFrameOcrTimingStream(
            track: track,
            anchorIndex: 10,
            text: ' 走り出した。\r\n',
          );
      expect(built, isNotNull);
      expect(built!.anchor.text, '走り出した。');
      expect(built.anchor.startMs, 30000);
      expect(built.anchor.endMs, 32000);
      expect(built.stream, contains(same(built.anchor)));
      for (final AudioCue cue in built.stream) {
        if (identical(cue, built.anchor)) continue;
        expect(cue.text, isEmpty, reason: '另一种语言的字幕不能进卡片');
      }
    });

    test('两侧各最多 8 句，贴着轨首也不越界', () {
      final ({AudioCue anchor, List<AudioCue> stream}) mid =
          buildFrameOcrTimingStream(track: track, anchorIndex: 10, text: 'あ')!;
      expect(mid.stream, hasLength(17));
      final ({AudioCue anchor, List<AudioCue> stream}) head =
          buildFrameOcrTimingStream(track: track, anchorIndex: 1, text: 'あ')!;
      expect(head.stream, hasLength(10));
      expect(head.stream.indexOf(head.anchor), 1);
    });

    test('OCR 文字为空 / 下标越界 → null', () {
      expect(
        buildFrameOcrTimingStream(track: track, anchorIndex: 3, text: '  '),
        isNull,
      );
      expect(
        buildFrameOcrTimingStream(track: track, anchorIndex: 20, text: 'あ'),
        isNull,
      );
    });
  });

  group('subtitleSentenceOf', () {
    GraphicSubtitleOcrChar char(String sentence, int index, double y) => (
      sentence: sentence,
      graphemeIndex: index,
      rect: Rect.fromLTWH(100.0 + index * 20, y, 20, 20),
    );

    test('取最靠下的那句（字幕在下方，招牌 / 标题在上方）', () {
      final GraphicSubtitleOcrFrame frame = GraphicSubtitleOcrFrame(
        imageSize: const Size(1920, 1080),
        chars: <GraphicSubtitleOcrChar>[
          char('喫茶店', 0, 120),
          char('喫茶店', 1, 120),
          char('もう帰ろう。', 0, 960),
          char('もう帰ろう。', 1, 960),
        ],
      );
      expect(subtitleSentenceOf(frame), 'もう帰ろう。');
    });

    test('这一帧没有字 → 空串（留一行可编辑的空句）', () {
      expect(
        subtitleSentenceOf(
          const GraphicSubtitleOcrFrame(
            imageSize: Size(1920, 1080),
            chars: <GraphicSubtitleOcrChar>[],
          ),
        ),
        isEmpty,
      );
    });
  });

  group('接线', () {
    test('控制器：伪字幕流先于其它流被认领，调轴跟伪流走', () {
      final String source = _read(
        'lib/src/media/video/video_player_controller.dart',
      );
      final int owning = source.indexOf('List<AudioCue> cueStreamOwning(');
      expect(
        source.substring(owning, owning + 400),
        contains('_frameOcrPseudoStream'),
      );
      final int delay = source.indexOf('int delayMsForCue(AudioCue cue) {');
      expect(
        source.substring(delay, delay + 200),
        contains('isFrameOcrPseudoCue(cue)'),
      );
      // 有文本轨覆盖暂停位置时借它的时间。
      expect(source, contains('_frameOcrTextTimingStream('));
      // 换片时伪流跟着清掉。
      expect(source, contains('_frameOcrPseudoStream = null;'));
    });

    test('页面：点字后开始贴边；普通「+」最多等一会儿，高级制卡打开前等', () {
      final String page = _read(
        'lib/src/pages/implementations/video_fushi_page.dart',
      );
      final int tap = page.indexOf('_handleGraphicSubtitleOcrLookupTap(');
      expect(
        page.substring(tap, tap + 3000),
        contains('_startFrameOcrSpeechSnap(controller, anchor)'),
      );

      final String mining = _read(
        'lib/src/pages/implementations/video_fushi/lookup_mining.part.dart',
      );
      expect(
        RegExp(
          r'overrides == null && _frameOcrSnapPending',
        ).allMatches(mining).length,
        2,
        reason: '制卡与覆盖最新卡两条路都要等，且只在没有高级制卡覆盖项时等',
      );
      expect(mining, contains('_fillFrameOcrNeighbourText(controller'));

      final String dialog = _read(
        'lib/src/pages/implementations/video_fushi/advanced_mining.part.dart',
      );
      final int build = dialog.indexOf('_buildAdvancedMiningSectionsImpl()');
      final String body = dialog.substring(build);
      expect(
        body.indexOf('_awaitFrameOcrSpeechSnap()'),
        lessThan(body.indexOf('_VideoAdvancedMiningSession(')),
        reason: '会话建好之后贴边就不再改区间，所以要在建会话之前等',
      );
      expect(
        body.indexOf('controller.screenshot()'),
        lessThan(body.indexOf('_awaitFrameOcrSpeechSnap()')),
        reason: '锁查词画面必须在首个 await 之前',
      );
      expect(
        dialog,
        contains('markersMs: _frameOcrSegmentMarkers(controller)'),
      );
    });

    test('等待有上限（1 秒），贴边失败时保持固定窗口', () {
      final String part = _read(
        'lib/src/pages/implementations/video_fushi/hardsub_speech.part.dart',
      );
      expect(
        part,
        contains(
          'const Duration _kFrameOcrSpeechSnapWaitCap = Duration(seconds: 1);',
        ),
      );
      expect(part, contains('.timeout(_kFrameOcrSpeechSnapWaitCap'));
      expect(part, contains('videoPauseOcrSpeechSnapEnabled'));
      expect(part, contains('frameOcrFallbackUsesTextTiming(anchor)'));
    });

    test('设置项：「贴合说话」开关登记、键已登记', () {
      final String schema = _read(
        'lib/src/settings/settings_schema_video.dart',
      );
      expect(schema, contains("id: 'video.subtitle.pause_ocr_speech_snap'"));
      final String keys = _read('lib/src/models/preference_keys.dart');
      expect(keys, contains("'video_pause_ocr_speech_snap',"));
    });
  });
}
