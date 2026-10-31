part of '../video_fushi_page.dart';

/// 制卡时最多再等「按说话贴边」多久：查词浮层打开时就开始抽包络，用户读释义的工夫
/// 通常已经做完；没做完就最多等这么久，再不行用固定窗口制卡，绝不卡住制卡。
const Duration _kFrameOcrSpeechSnapWaitCap = Duration(seconds: 1);

/// 给硬字幕上一句 / 下一句补文字时，单句识别最多等多久；超时就留一行空句让用户填。
const Duration _kFrameOcrNeighbourOcrTimeout = Duration(seconds: 8);

/// 最近一次贴边抽到的能量包络（播放器轴，第 i 帧从 `startMs + i * 20ms` 起）。
typedef _FrameOcrEnvelope = ({
  String source,
  int? audioStreamIndex,
  int startMs,
  List<double> frames,
});

/// 硬字幕（烧进画面、没有字幕轨）暂停 OCR 制卡的「按说话贴边」与上一句 / 下一句。
///
/// 流程：点字查词 → [frameOcrFallbackCue] 先给固定窗口（同步，制卡随时可用）→
/// [_startFrameOcrSpeechSnap] 在后台抽暂停位置附近的能量包络、切说话段
/// （[snapSpeechAroundPause]），做完就把锚点原地改成那一段、相邻段建成伪字幕流
/// （[VideoPlayerController.adoptFrameOcrSpeechSnap]）。高级制卡「加上一句 / 加下一句」
/// 走现成的 [_setSentenceContextToDraft]（在伪字幕流里取邻句），空文本的邻句在这里
/// OCR 那一刻的画面补字。任何一步失败都停在固定窗口，不比原来差。
extension _VideoHardSubSpeech on _VideoFushiPageState {
  /// 本机媒体文件路径（贴边 / 补字要随机读本机字节）；在线流 / 远端返回 null。
  /// 文件是否真的存在交给后续的异步 stat（网络盘上同步 stat 会卡 UI，BUG-3756）。
  String? _frameOcrLocalSource(VideoPlayerController controller) {
    final String? source = controller.miningSource;
    if (source == null || isNetworkStreamUri(source) || !p.isAbsolute(source)) {
      return null;
    }
    return source;
  }

  /// 硬字幕锚点 [anchor] 刚建好：开关开着、时间不是借文本轨的、是本机文件时，开始
  /// 后台贴边。
  void _startFrameOcrSpeechSnap(
    VideoPlayerController controller,
    AudioCue anchor,
  ) {
    if (!appModel.videoPauseOcrSpeechSnapEnabled) return;
    if (controller.frameOcrFallbackUsesTextTiming(anchor)) return;
    final int? pauseMs = controller.frameOcrFallbackStillMs(anchor);
    final String? source = _frameOcrLocalSource(controller);
    if (pauseMs == null || source == null) return;
    _frameOcrSnapAnchor = anchor;
    _frameOcrSnapDone = false;
    _frameOcrSnap = _runFrameOcrSpeechSnap(controller, anchor, source, pauseMs)
        .whenComplete(() {
          if (identical(_frameOcrSnapAnchor, anchor)) _frameOcrSnapDone = true;
        });
  }

  /// 当前查词锚点的贴边还没做完。
  bool get _frameOcrSnapPending =>
      !_frameOcrSnapDone &&
      _frameOcrSnap != null &&
      identical(_frameOcrSnapAnchor, _lastLookupCue);

  /// 等当前锚点的贴边做完，最多 [_kFrameOcrSpeechSnapWaitCap]；超时照常往下走（用
  /// 固定窗口），贴边稍后做完也不会改已经制好的卡。
  Future<void> _awaitFrameOcrSpeechSnap() async {
    final Future<void>? pending = _frameOcrSnap;
    if (pending == null) return;
    await pending.timeout(_kFrameOcrSpeechSnapWaitCap, onTimeout: () {});
  }

  Future<void> _runFrameOcrSpeechSnap(
    VideoPlayerController controller,
    AudioCue anchor,
    String source,
    int pauseMs,
  ) async {
    try {
      final int startMs = math.max(0, pauseMs - kSpeechSnapLookBackMs);
      final int endMs = pauseMs + kSpeechSnapLookAheadMs;
      final int? audioStreamIndex = controller.currentAudioStreamIndex;
      final Stopwatch watch = Stopwatch()..start();
      // 同一个暂停位置上连点几个字：上一次抽的包络就够用，不再跑 ffmpeg。
      final List<double> frames =
          _frameOcrEnvelopeSlice(
            source: source,
            audioStreamIndex: audioStreamIndex,
            startMs: startMs,
            endMs: endMs,
          ) ??
          await extractAudioEnergyEnvelope(
            videoPath: source,
            windowMs: kSubtitleWaveformWindowMs,
            audioStreamIndex: audioStreamIndex,
            audioStreamCount: controller.realAudioStreamCount,
            limitMs: endMs - startMs,
            startMs: startMs,
          );
      debugPrint(
        '[hardsub-snap] envelope ${watch.elapsedMilliseconds} ms, '
        '${frames.length} frames',
      );
      if (frames.isEmpty || !mounted || !identical(_controller, controller)) {
        return;
      }
      _frameOcrEnvelope = (
        source: source,
        audioStreamIndex: audioStreamIndex,
        startMs: startMs,
        frames: frames,
      );
      final SpeechSnapResult? result = snapSpeechAroundPause(
        envelopeDb: frames,
        envelopeStartMs: startMs,
        frameMs: kSubtitleWaveformWindowMs,
        pauseMs: pauseMs,
      );
      if (result == null) {
        debugPrint('[hardsub-snap] no clear speech edge; fixed window kept');
        return;
      }
      // 用户已经换了一句查 / 已经开始改这张卡（加了上下文、开着高级制卡）：不在他
      // 手底下改区间。
      if (!identical(_lastLookupCue, anchor) ||
          !_miningDraft.isEmpty ||
          _advancedMiningSession != null) {
        return;
      }
      if (controller.adoptFrameOcrSpeechSnap(anchor, result)) {
        final SpeechSegment line = result.segments[result.anchorIndex];
        debugPrint(
          '[hardsub-snap] line ${line.startMs}-${line.endMs} ms '
          '(pause $pauseMs), ${result.segments.length} segment(s) in reach',
        );
      }
    } catch (error, stack) {
      ErrorLogService.instance.log('video.hardSubSpeechSnap', error, stack);
    }
  }

  /// 高级制卡的波形：最近一次贴边抽的包络覆盖得到 `[startMs, endMs)` 就直接切出来，
  /// 不再跑一遍 ffmpeg；覆盖不到返回 null（调用方照常去抽）。
  List<double>? _frameOcrEnvelopeSlice({
    required String source,
    required int? audioStreamIndex,
    required int startMs,
    required int endMs,
  }) {
    final _FrameOcrEnvelope? cached = _frameOcrEnvelope;
    if (cached == null ||
        cached.source != source ||
        cached.audioStreamIndex != audioStreamIndex) {
      return null;
    }
    const int frameMs = kSubtitleWaveformWindowMs;
    final int first = (startMs - cached.startMs) ~/ frameMs;
    final int last = (endMs - cached.startMs + frameMs - 1) ~/ frameMs;
    if (startMs < cached.startMs || last > cached.frames.length) return null;
    return cached.frames.sublist(first, last);
  }

  /// 伪字幕流里的句子边界（播放器轴），给波形画淡虚线；不是硬字幕伪流时为空。
  List<int> _frameOcrSegmentMarkers(VideoPlayerController controller) {
    final AudioCue? anchor = _lastLookupCue;
    if (anchor == null || !controller.isFrameOcrPseudoCue(anchor)) {
      return const <int>[];
    }
    return <int>[
      for (final AudioCue cue in controller.cueStreamOwning(anchor)) ...<int>[
        miningClipTimeMs(cue.startMs, controller.delayMsForCue(cue)),
        miningClipTimeMs(cue.endMs, controller.delayMsForCue(cue)),
      ],
    ];
  }

  /// 给加进制卡上下文的硬字幕邻句补文字：文本为空、还没识别过的，抽那句中间时刻的
  /// 一帧做 OCR，取最像字幕的那一行（[subtitleSentenceOf]）。识别不出 / 超时 / 引擎
  /// 不可用就留空（空句不进卡片文本，用户可以在高级制卡里填）。只处理本机文件。
  Future<void> _fillFrameOcrNeighbourText(
    VideoPlayerController controller,
    List<AudioCue> cues,
  ) async {
    final String? source = _frameOcrLocalSource(controller);
    if (source == null) return;
    for (final AudioCue cue in cues) {
      if (!controller.isFrameOcrPseudoCue(cue) || cue.text.isNotEmpty) continue;
      if (!_frameOcrNeighbourTried.add(cue)) continue;
      final int midMs = miningClipTimeMs(
        (cue.startMs + cue.endMs) ~/ 2,
        controller.delayMsForCue(cue),
      );
      final String text = await _recognizeFrameOcrLine(
        source,
        midMs,
      ).timeout(_kFrameOcrNeighbourOcrTimeout, onTimeout: () => '');
      if (!mounted || !identical(_controller, controller)) return;
      if (text.isNotEmpty) cue.text = text;
    }
  }

  /// 抽 [atMs]（播放器轴）那一帧，交给暂停 OCR 同一套引擎识别，返回最像字幕的那行。
  Future<String> _recognizeFrameOcrLine(String source, int atMs) async {
    final Directory dir = await getTemporaryDirectory();
    final String output = p.join(
      dir.path,
      'hardsub_neighbour_${DateTime.now().microsecondsSinceEpoch}.png',
    );
    try {
      final String? produced = await extractVideoFrameViaFfmpeg(
        inputPath: source,
        outputPath: output,
        atSeconds: atMs / 1000.0,
        diagnosticOnly: true,
      );
      if (produced == null || !mounted) return '';
      final Uint8List bytes = await File(produced).readAsBytes();
      final GraphicSubtitleOcrSession session = _frameOcrNeighbourSession ??=
          GraphicSubtitleOcrSession(
            prepare: (String workDirPath) =>
                _prepareGraphicSubtitleOcr(workDirPath),
          );
      final GraphicSubtitleOcrFrame? frame = await session.recognize(bytes);
      return frame == null ? '' : subtitleSentenceOf(frame);
    } on GraphicSubtitleOcrUnavailable {
      return '';
    } catch (error, stack) {
      ErrorLogService.instance.log('video.hardSubNeighbourOcr', error, stack);
      return '';
    } finally {
      try {
        final File file = File(output);
        if (file.existsSync()) file.deleteSync();
      } on FileSystemException catch (_) {}
    }
  }
}
