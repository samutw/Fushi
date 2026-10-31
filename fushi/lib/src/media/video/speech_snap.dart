/// 硬字幕（烧进画面、没有字幕轨）暂停 OCR 制卡的「按说话贴边」：把暂停位置附近一小段
/// 音频的能量包络（[extractAudioEnergyEnvelope] 的逐帧 RMS dB）切成一段段说话，句子
/// 音频取暂停位置所在的那一段，而不是盲取「前后各 N 秒」。相邻的说话段（间隔够短）
/// 充当上一句 / 下一句，让高级制卡的「加上一句 / 加下一句」在硬字幕上也能用。
///
/// 全部是纯函数（无 IO），调用方负责抽包络与回落：任何一步给不出结果（包络为空、
/// 没有明显静音间隔、整段都是持续的背景音乐）都返回空 / null，调用方保持原来的固定
/// 窗口——这条路径只会让区间更准，不会比原来更差。
library;

import 'dart:math' as math;

/// 一段说话（播放器轴毫秒，左闭右开）。
typedef SpeechSegment = ({int startMs, int endMs});

/// 抽包络的范围：暂停位置往前 / 往后各读多少（毫秒）。往前读得多：用户通常是听完
/// 一句才暂停，这句和它的上一句都在暂停位置之前。
const int kSpeechSnapLookBackMs = 10000;
const int kSpeechSnapLookAheadMs = 6000;

/// 两段说话之间至少要静这么久才算「换了一句」（毫秒）。比单纯的换气 / 逗号停顿
/// （日语对白里常见 200–350 ms）长，免得把一句话从中间切开。
const int kSpeechSnapSplitGapMs = 400;

/// 短于这个的「说话」当噪声丢掉（毫秒）：关门声、按键音之类的短促响声。
const int kSpeechSnapMinSpeechMs = 120;

/// 每段说话前后各留多少（毫秒），免得切掉开头的辅音和收尾的气声。只在与邻段之间
/// 的空隙里留，不会吃进邻段。
const int kSpeechSnapPadMs = 150;

/// 锚定那一段的边界离暂停位置最多多远（毫秒）：往前 4 秒、往后 2 秒。超出的部分
/// 截掉；两侧都截到上限（说明根本没找到静音，多半是持续的音乐）就算贴边失败。
const int kSpeechSnapMaxBackMs = 4000;
const int kSpeechSnapMaxForwardMs = 2000;

/// 暂停落在两段说话之间的空档里时，往前 / 往后最多找多远的那一段（毫秒）。
/// 往前容忍得更多：读完字幕才按暂停，往往已经过了这句的结尾。
const int kSpeechSnapGapLookBackMs = 1500;
const int kSpeechSnapGapLookAheadMs = 1000;

/// 相邻的说话段之间的间隔不超过这么多（毫秒）才能被「加上一句 / 加下一句」接进来；
/// 更长的间隔多半是换了场景 / 换了人，按钮据此停用。
const int kSpeechNeighbourMaxGapMs = 1500;

/// 包络的动态范围（最响与底噪之差）低于这个（dB）就不切：整段一样响（持续的音乐 /
/// 嘈杂环境）或一样静，没有可信的说话边界。
const double kSpeechSnapMinContrastDb = 10;

/// 「说话」门限放在底噪与最响之间的哪个位置（0 = 底噪，1 = 最响）。
const double kSpeechSnapThresholdRatio = 0.4;

/// 把能量包络切成说话段。
///
/// [envelopeDb]：逐帧 RMS（dB，越大越响），第 i 帧覆盖
/// `[envelopeStartMs + i * frameMs, envelopeStartMs + (i + 1) * frameMs)`。
/// 门限按这段包络自己的底噪（10 分位）与最响（95 分位）定，安静场景和背景乐场景
/// 都能用；动态范围不足 [kSpeechSnapMinContrastDb] 返回空列表。
///
/// 返回的段按时间排序，**未加留白**（留白见 [padSpeechSegments]）。
List<SpeechSegment> detectSpeechSegments({
  required List<double> envelopeDb,
  required int envelopeStartMs,
  required int frameMs,
  int splitGapMs = kSpeechSnapSplitGapMs,
  int minSpeechMs = kSpeechSnapMinSpeechMs,
}) {
  if (envelopeDb.isEmpty || frameMs <= 0) return const <SpeechSegment>[];
  final List<double> sorted = List<double>.of(envelopeDb)..sort();
  double percentile(double q) =>
      sorted[(q * (sorted.length - 1)).round().clamp(0, sorted.length - 1)];
  final double floorDb = percentile(0.10);
  final double peakDb = percentile(0.95);
  if (peakDb - floorDb < kSpeechSnapMinContrastDb) {
    return const <SpeechSegment>[];
  }
  final double threshold =
      floorDb + (peakDb - floorDb) * kSpeechSnapThresholdRatio;

  // 先取「高于门限」的连续帧，再把间隔短于 splitGapMs 的相邻段并起来。
  final List<SpeechSegment> raw = <SpeechSegment>[];
  int? runStart;
  for (int i = 0; i <= envelopeDb.length; i++) {
    final bool voiced = i < envelopeDb.length && envelopeDb[i] >= threshold;
    if (voiced) {
      runStart ??= i;
    } else if (runStart != null) {
      raw.add((
        startMs: envelopeStartMs + runStart * frameMs,
        endMs: envelopeStartMs + i * frameMs,
      ));
      runStart = null;
    }
  }
  final List<SpeechSegment> merged = <SpeechSegment>[];
  for (final SpeechSegment segment in raw) {
    if (merged.isNotEmpty && segment.startMs - merged.last.endMs < splitGapMs) {
      merged[merged.length - 1] = (
        startMs: merged.last.startMs,
        endMs: segment.endMs,
      );
    } else {
      merged.add(segment);
    }
  }
  return <SpeechSegment>[
    for (final SpeechSegment segment in merged)
      if (segment.endMs - segment.startMs >= minSpeechMs) segment,
  ];
}

/// 给每段说话前后各留 [padMs]，但只留在与邻段之间空隙的一半以内（不吃进邻段），
/// 并夹在 `[lowerMs, upperMs]` 内（包络覆盖的范围 / 片头 0）。
List<SpeechSegment> padSpeechSegments(
  List<SpeechSegment> segments, {
  int padMs = kSpeechSnapPadMs,
  required int lowerMs,
  required int upperMs,
}) {
  return <SpeechSegment>[
    for (int i = 0; i < segments.length; i++)
      (
        startMs: math.max(
          i == 0
              ? lowerMs
              : segments[i - 1].endMs +
                    (segments[i].startMs - segments[i - 1].endMs) ~/ 2,
          segments[i].startMs - padMs,
        ),
        endMs: math.min(
          i == segments.length - 1
              ? upperMs
              : segments[i].endMs +
                    (segments[i + 1].startMs - segments[i].endMs) ~/ 2,
          segments[i].endMs + padMs,
        ),
      ),
  ];
}

/// 暂停位置 [pauseMs] 对应的那段说话的下标：
/// 1. 暂停落在某段里 → 那一段；
/// 2. 落在空档里 → 前面 [gapLookBackMs] 内刚结束的那段（读完字幕才暂停），
///    否则后面 [gapLookAheadMs] 内马上开始的那段；
/// 3. 都没有 → null（调用方回落固定窗口）。
int? speechSegmentIndexAt(
  List<SpeechSegment> segments,
  int pauseMs, {
  int gapLookBackMs = kSpeechSnapGapLookBackMs,
  int gapLookAheadMs = kSpeechSnapGapLookAheadMs,
}) {
  int? before;
  int? after;
  for (int i = 0; i < segments.length; i++) {
    final SpeechSegment segment = segments[i];
    if (segment.startMs <= pauseMs && pauseMs < segment.endMs) return i;
    if (segment.endMs <= pauseMs) before = i;
    if (segment.startMs > pauseMs && after == null) after = i;
  }
  if (before != null && pauseMs - segments[before].endMs <= gapLookBackMs) {
    return before;
  }
  if (after != null && segments[after].startMs - pauseMs <= gapLookAheadMs) {
    return after;
  }
  return null;
}

/// 从 [anchorIndex] 往两边接：相邻两段间隔不超过 [maxGapMs] 就接上，遇到更长的间隔
/// 就停。返回接上的那一串（按时间排序）以及锚段在其中的下标。
({List<SpeechSegment> chain, int anchorIndex}) chainSpeechNeighbours(
  List<SpeechSegment> segments,
  int anchorIndex, {
  int maxGapMs = kSpeechNeighbourMaxGapMs,
}) {
  int first = anchorIndex;
  while (first > 0 &&
      segments[first].startMs - segments[first - 1].endMs <= maxGapMs) {
    first--;
  }
  int last = anchorIndex;
  while (last < segments.length - 1 &&
      segments[last + 1].startMs - segments[last].endMs <= maxGapMs) {
    last++;
  }
  return (
    chain: segments.sublist(first, last + 1),
    anchorIndex: anchorIndex - first,
  );
}

/// 硬字幕暂停 OCR 的贴边结果：一串说话段（播放器轴，已留白）+ 锚段下标。
typedef SpeechSnapResult = ({List<SpeechSegment> segments, int anchorIndex});

/// 一步到位：包络 → 说话段 → 锚段 → 邻段串，锚段按 [maxBackMs] / [maxForwardMs]
/// 截到暂停位置附近。
///
/// 返回 null（调用方保持固定窗口）的情形：包络为空 / 没有动态范围、暂停附近找不到
/// 说话、锚段两侧都被截到上限（根本没有静音边界）。
SpeechSnapResult? snapSpeechAroundPause({
  required List<double> envelopeDb,
  required int envelopeStartMs,
  required int frameMs,
  required int pauseMs,
  int maxBackMs = kSpeechSnapMaxBackMs,
  int maxForwardMs = kSpeechSnapMaxForwardMs,
  int neighbourMaxGapMs = kSpeechNeighbourMaxGapMs,
}) {
  final List<SpeechSegment> segments = detectSpeechSegments(
    envelopeDb: envelopeDb,
    envelopeStartMs: envelopeStartMs,
    frameMs: frameMs,
  );
  final int? index = speechSegmentIndexAt(segments, pauseMs);
  if (index == null) return null;
  final ({List<SpeechSegment> chain, int anchorIndex}) chained =
      chainSpeechNeighbours(segments, index, maxGapMs: neighbourMaxGapMs);
  final List<SpeechSegment> padded = padSpeechSegments(
    chained.chain,
    lowerMs: math.max(0, envelopeStartMs),
    upperMs: envelopeStartMs + envelopeDb.length * frameMs,
  );
  final SpeechSegment anchor = padded[chained.anchorIndex];
  final int lower = math.max(0, pauseMs - maxBackMs);
  final int upper = pauseMs + maxForwardMs;
  final bool clippedStart = anchor.startMs < lower;
  final bool clippedEnd = anchor.endMs > upper;
  if (clippedStart && clippedEnd) return null;
  final SpeechSegment clipped = (
    startMs: math.max(anchor.startMs, lower),
    endMs: math.min(anchor.endMs, upper),
  );
  if (clipped.endMs <= clipped.startMs) return null;
  return (
    segments: <SpeechSegment>[
      for (int i = 0; i < padded.length; i++)
        i == chained.anchorIndex ? clipped : padded[i],
    ],
    anchorIndex: chained.anchorIndex,
  );
}
