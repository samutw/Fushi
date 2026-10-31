import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/speech_snap.dart';

/// 硬字幕暂停 OCR 的「按说话贴边」纯算法：包络 → 说话段 → 锚段 → 邻段串。
///
/// 包络用 20 ms 一帧的合成 dB 序列：[speech] 里列出的区间是 -20 dB（说话），其余是
/// [floorDb]（安静场景 -60 dB，背景乐场景抬高到 -35 dB）。
const int _frameMs = 20;

List<double> _envelope({
  required int lengthMs,
  required List<(int, int)> speech,
  double floorDb = -60,
  double speechDb = -20,
}) {
  return <double>[
    for (int t = 0; t < lengthMs; t += _frameMs)
      speech.any(((int, int) s) => t >= s.$1 && t < s.$2) ? speechDb : floorDb,
  ];
}

void main() {
  group('detectSpeechSegments', () {
    test('清晰的两句：按静音切开，时刻带上包络起点', () {
      final List<SpeechSegment> segments = detectSpeechSegments(
        envelopeDb: _envelope(
          lengthMs: 8000,
          speech: <(int, int)>[(1000, 3000), (4000, 6000)],
        ),
        envelopeStartMs: 50000,
        frameMs: _frameMs,
      );
      expect(segments, <SpeechSegment>[
        (startMs: 51000, endMs: 53000),
        (startMs: 54000, endMs: 56000),
      ]);
    });

    test('句中短停顿（逗号、换气）不切开一句话', () {
      final List<SpeechSegment> segments = detectSpeechSegments(
        envelopeDb: _envelope(
          lengthMs: 8000,
          speech: <(int, int)>[(1000, 2000), (2300, 3500)],
        ),
        envelopeStartMs: 0,
        frameMs: _frameMs,
      );
      expect(segments, <SpeechSegment>[(startMs: 1000, endMs: 3500)]);
    });

    test('背景乐抬高底噪：门限跟着包络自己走，照样切得出', () {
      final List<SpeechSegment> segments = detectSpeechSegments(
        envelopeDb: _envelope(
          lengthMs: 8000,
          speech: <(int, int)>[(1000, 3000)],
          floorDb: -35,
        ),
        envelopeStartMs: 0,
        frameMs: _frameMs,
      );
      expect(segments, <SpeechSegment>[(startMs: 1000, endMs: 3000)]);
    });

    test('一样响（持续的音乐）或一样静：没有可信边界 → 空', () {
      expect(
        detectSpeechSegments(
          envelopeDb: List<double>.filled(400, -22),
          envelopeStartMs: 0,
          frameMs: _frameMs,
        ),
        isEmpty,
      );
      expect(
        detectSpeechSegments(
          envelopeDb: const <double>[],
          envelopeStartMs: 0,
          frameMs: _frameMs,
        ),
        isEmpty,
      );
    });

    test('短促的响声（关门、按键）当噪声丢掉', () {
      final List<SpeechSegment> segments = detectSpeechSegments(
        envelopeDb: _envelope(
          lengthMs: 8000,
          speech: <(int, int)>[(1000, 1060), (4000, 6000)],
        ),
        envelopeStartMs: 0,
        frameMs: _frameMs,
      );
      expect(segments, <SpeechSegment>[(startMs: 4000, endMs: 6000)]);
    });
  });

  group('padSpeechSegments', () {
    test('前后各留白，但只留到与邻段空隙的一半，夹在包络范围内', () {
      final List<SpeechSegment> padded = padSpeechSegments(
        const <SpeechSegment>[
          (startMs: 100, endMs: 2000),
          (startMs: 2200, endMs: 4000),
        ],
        padMs: 150,
        lowerMs: 0,
        upperMs: 4100,
      );
      expect(padded, <SpeechSegment>[
        (startMs: 0, endMs: 2100),
        (startMs: 2100, endMs: 4100),
      ]);
    });
  });

  group('speechSegmentIndexAt', () {
    const List<SpeechSegment> segments = <SpeechSegment>[
      (startMs: 1000, endMs: 3000),
      (startMs: 6000, endMs: 8000),
    ];

    test('暂停落在一段里 → 那一段', () {
      expect(speechSegmentIndexAt(segments, 2000), 0);
      expect(speechSegmentIndexAt(segments, 7999), 1);
    });

    test('读完字幕才暂停：刚结束的那段优先', () {
      expect(speechSegmentIndexAt(segments, 4200), 0);
    });

    test('空档里离上一段太远、下一段马上开始 → 下一段', () {
      expect(speechSegmentIndexAt(segments, 5200), 1);
    });

    test('前后都够不着 → null（回落固定窗口）', () {
      expect(speechSegmentIndexAt(segments, 4700), isNull);
      expect(speechSegmentIndexAt(const <SpeechSegment>[], 4700), isNull);
    });
  });

  group('chainSpeechNeighbours', () {
    test('间隔不超过 1.5 秒就接上，遇到长间隔停下', () {
      const List<SpeechSegment> segments = <SpeechSegment>[
        (startMs: 0, endMs: 1000),
        (startMs: 4000, endMs: 5000), // 与上一段隔 3 秒：不接
        (startMs: 6000, endMs: 7000),
        (startMs: 8000, endMs: 9000),
        (startMs: 9500, endMs: 10000),
      ];
      final ({List<SpeechSegment> chain, int anchorIndex}) chained =
          chainSpeechNeighbours(segments, 2);
      expect(chained.chain, segments.sublist(1));
      expect(chained.anchorIndex, 1);
    });
  });

  group('snapSpeechAroundPause', () {
    test('暂停在一句里：区间是那一句（带留白），相邻的句子作邻段', () {
      final SpeechSnapResult? result = snapSpeechAroundPause(
        envelopeDb: _envelope(
          lengthMs: 16000,
          speech: <(int, int)>[(3000, 5000), (6000, 9000), (14000, 15000)],
        ),
        envelopeStartMs: 50000,
        frameMs: _frameMs,
        pauseMs: 58500,
      );
      expect(result, isNotNull);
      expect(result!.segments[result.anchorIndex], (
        startMs: 55850,
        endMs: 59150,
      ));
      // 上一句隔 1 秒接上；下一句隔 5 秒不接。
      expect(result.segments, hasLength(2));
      expect(result.anchorIndex, 1);
      expect(result.segments.first, (startMs: 52850, endMs: 55150));
    });

    test('一句比上限长：只截一侧，另一侧仍是真边界', () {
      final SpeechSnapResult? result = snapSpeechAroundPause(
        envelopeDb: _envelope(
          lengthMs: 16000,
          speech: <(int, int)>[(1000, 9000)],
        ),
        envelopeStartMs: 0,
        frameMs: _frameMs,
        pauseMs: 8000,
      );
      expect(result!.segments.single, (
        startMs: 8000 - kSpeechSnapMaxBackMs,
        endMs: 9150,
      ));
    });

    test('整段都是响的（没有静音边界）→ null，保持固定窗口', () {
      expect(
        snapSpeechAroundPause(
          envelopeDb: List<double>.filled(800, -22),
          envelopeStartMs: 0,
          frameMs: _frameMs,
          pauseMs: 8000,
        ),
        isNull,
      );
    });

    test('锚段两侧都被截到上限（说话盖满了暂停前后）→ null', () {
      // 前后各留了足够的静音给门限定底噪，切得出这一段；但它从暂停前 6 秒一直到
      // 暂停后 6 秒，两侧都超出上限。
      expect(
        snapSpeechAroundPause(
          envelopeDb: _envelope(
            lengthMs: 16000,
            speech: <(int, int)>[(2000, 14000)],
          ),
          envelopeStartMs: 0,
          frameMs: _frameMs,
          pauseMs: 8000,
        ),
        isNull,
      );
    });

    test('片头：包络从 0 读起，暂停在第一句里也能贴边', () {
      final SpeechSnapResult? result = snapSpeechAroundPause(
        envelopeDb: _envelope(lengthMs: 6000, speech: <(int, int)>[(80, 1500)]),
        envelopeStartMs: 0,
        frameMs: _frameMs,
        pauseMs: 700,
      );
      expect(result!.segments.single, (startMs: 0, endMs: 1650));
    });

    test('暂停附近没有说话 → null', () {
      expect(
        snapSpeechAroundPause(
          envelopeDb: _envelope(
            lengthMs: 16000,
            speech: <(int, int)>[(500, 1500)],
          ),
          envelopeStartMs: 0,
          frameMs: _frameMs,
          pauseMs: 12000,
        ),
        isNull,
      );
    });
  });
}
