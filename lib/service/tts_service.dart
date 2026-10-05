import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:get/get.dart';
import 'package:flutter/widgets.dart';
import 'package:hikari_novel_flutter/widgets/state_page.dart';
import 'package:url_launcher/url_launcher.dart';

import '../common/log.dart';
import 'local_storage_service.dart';

class TtsService extends GetxService {
  static const MethodChannel _intentChannel = MethodChannel('hikari/system_intents');

  static TtsService get instance => Get.find<TtsService>();

  final FlutterTts _tts = FlutterTts();

  final enabled = false.obs;
  final engine = RxnString();
  final voice = Rxn<Map<String, String>>();
  final rate = 0.5.obs;
  final pitch = 1.0.obs;
  final volume = 1.0.obs;

  final engines = <String>[].obs;
  final voices = <Map<String, String>>[].obs;

  final isPlaying = false.obs;
  final isPaused = false.obs;
  final lastSpokenText = ''.obs;

  bool _pauseRequested = false;
  bool _stopRequested = false;

  final isSessionActive = false.obs;
  final sessionTitle = ''.obs;
  final sessionProgress = 0.0.obs;

  /// 当前正在朗读的句块（用于阅读器高亮）
  final currentChunkIndex = (-1).obs;
  final currentChunkText = ''.obs;

  /// 当前正在朗读的段落索引（对应阅读页 text.split('\n\n') 的段落序号；-1 = 无）
  final currentParagraphIndex = (-1).obs;

  /// 会话代际：换章/停止时递增，丢弃过期 completion 回调
  int _sessionGen = 0;

  /// 睡眠定时（分钟）；0 = 不定时
  final sleepMinutes = 0.obs;
  final sleepRemaining = 0.obs;
  Timer? _sleepTimer;

  /// 读完本章后自动下一章
  final autoNextChapter = false.obs;

  /// 由阅读器注入：读完本章后调用
  Future<void> Function()? onChapterComplete;

  List<String> _chunks = const [];
  List<int> _chunkParagraphs = const [];
  int _chunkIndex = 0;

  static const int _maxChunkLen = 140;

  static const String multiTtsEnginePackage = 'org.nobody.multitts';

  static const List<String> _preferredLocales = <String>['zh-CN', 'zh-TW', 'zh-HK', 'en-US'];

  Future<void> init() async {
    try {
      await _tts.awaitSpeakCompletion(true);
    } catch (_) {}

    _tts.setStartHandler(() {
      isPlaying.value = true;
      isPaused.value = false;
    });
    _tts.setCompletionHandler(() {
      _onChunkCompleted();
    });
    _tts.setCancelHandler(() {
      if (_pauseRequested) {
        _pauseRequested = false;
        isPlaying.value = false;
        isPaused.value = true;
        return;
      }
      _stopRequested = false;
      _endSession();
    });
    _tts.setPauseHandler(() {
      _pauseRequested = false;
      isPlaying.value = false;
      isPaused.value = true;
    });
    _tts.setContinueHandler(() {
      _pauseRequested = false;
      isPlaying.value = true;
      isPaused.value = false;
    });
    _tts.setErrorHandler((_) {
      if (_pauseRequested) {
        _pauseRequested = false;
        isPlaying.value = false;
        isPaused.value = true;
        return;
      }
      _stopRequested = false;
      _endSession();
    });

    enabled.value = LocalStorageService.instance.getReaderTtsEnabled();
    engine.value = LocalStorageService.instance.getReaderTtsEngine();
    voice.value = LocalStorageService.instance.getReaderTtsVoice();
    rate.value = LocalStorageService.instance.getReaderTtsRate();
    pitch.value = LocalStorageService.instance.getReaderTtsPitch();
    volume.value = LocalStorageService.instance.getReaderTtsVolume();

    await _tts.setSpeechRate(rate.value);
    await _tts.setPitch(pitch.value);
    await _tts.setVolume(volume.value);

    await _applyBestLanguage();

    await refreshEngines();

    final savedEngine = engine.value;
    final hasSaved = savedEngine != null && savedEngine.isNotEmpty && engines.contains(savedEngine);
    if (hasSaved) {
      await applyEngine(savedEngine);
    } else {
      await applyEngine(null);
    }

    await _applyBestLanguage();

    await refreshVoices();
    final savedVoice = voice.value;
    if (savedVoice != null && voices.any((v) => v["name"] == savedVoice["name"] && v["locale"] == savedVoice["locale"])) {
      await applyVoice(savedVoice);
    } else {
      voice.value = null;
      LocalStorageService.instance.setReaderTtsVoice(null);
    }
  }

  String displayEngineName(String enginePackage) {
    if (enginePackage == multiTtsEnginePackage) return "MultiTTS";
    return "system_tts".tr;
  }

  Future<void> refreshEngines() async {
    if (!Platform.isAndroid) return;
    try {
      final result = await _tts.getEngines;
      final list = (result as List?)?.cast<String>() ?? <String>[];
      list.sort((a, b) {
        if (a == multiTtsEnginePackage && b != multiTtsEnginePackage) return -1;
        if (b == multiTtsEnginePackage && a != multiTtsEnginePackage) return 1;
        return a.compareTo(b);
      });
      engines.assignAll(list);
    } catch (e) {
      Log.d("[TtsService] getEngines failed: $e");

      engines.clear();
    }
  }

  Future<void> refreshVoices() async {
    try {
      final result = await _tts.getVoices;
      final list = <Map<String, String>>[];
      if (result is List) {
        for (final v in result) {
          if (v is Map) {
            final name = v["name"]?.toString();
            final locale = v["locale"]?.toString();
            if (name != null && locale != null) {
              list.add({"name": name, "locale": locale});
            }
          }
        }
      }
      voices.assignAll(list);
    } catch (e) {
      Log.d("[TtsService] getVoices failed: $e");

      voices.clear();
    }
  }

  Future<void> setEnabled(bool v) async {
    enabled.value = v;
    LocalStorageService.instance.setReaderTtsEnabled(v);
    if (!v) await stop();
  }

  Future<void> applyEngine(String? e) async {
    engine.value = e;
    LocalStorageService.instance.setReaderTtsEngine(e);
    if (Platform.isAndroid && e != null && e.isNotEmpty) {
      try {
        await _tts.setEngine(e);
      } catch (err) {
        Log.d("[TtsService] setEngine failed: $err");
      }
    }
    await _applyBestLanguage();
  }

  Future<void> applyVoice(Map<String, String>? v) async {
    voice.value = v;
    LocalStorageService.instance.setReaderTtsVoice(v);
    if (v == null) return;
    try {
      await _tts.setVoice(v);
    } catch (err) {
      Log.d("[TtsService] setVoice failed: $err");
    }
  }

  Future<void> setRate(double v) async {
    rate.value = v;
    LocalStorageService.instance.setReaderTtsRate(v);
    await _tts.setSpeechRate(v);
  }

  Future<void> setPitch(double v) async {
    pitch.value = v;
    LocalStorageService.instance.setReaderTtsPitch(v);
    await _tts.setPitch(v);
  }

  Future<void> setVolume(double v) async {
    volume.value = v;
    LocalStorageService.instance.setReaderTtsVolume(v);
    await _tts.setVolume(v);
  }

  Future<void> refreshSettings({bool restartIfPlaying = true}) async {
    if (!enabled.value) return;

    if (restartIfPlaying && (isPlaying.value || isPaused.value || isSessionActive.value)) {
      try {
        await pauseSession();
      } catch (_) {}

      await _prepareForSpeak();

      try {
        await resumeSession();
      } catch (_) {
        if (lastSpokenText.value.trim().isNotEmpty) {
          await speak(lastSpokenText.value);
        }
      }
      return;
    }

    await _prepareForSpeak();
  }

  Future<void> openAndroidTtsSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _intentChannel.invokeMethod('openTtsSettings');
    } catch (e) {
      Log.d("[TtsService] openTtsSettings failed: $e");
      showSnackBar(message: "${"unable_to_open_system_setting".tr}: $e", context: Get.context!);
    }
  }

  Future<void> openAndroidApp(String packageName) async {
    if (!Platform.isAndroid) return;
    try {
      await _intentChannel.invokeMethod('openApp', {'package': packageName});
    } catch (e) {
      Log.d("[TtsService] openApp failed: $e");
    }
  }

  Future<void> openMultiTtsStore() async {
    final pkg = multiTtsEnginePackage;
    final market = Uri.parse('market://details?id=$pkg');
    final web = Uri.parse('https://play.google.com/store/apps/details?id=$pkg');
    if (await canLaunchUrl(market)) {
      await launchUrl(market, mode: LaunchMode.externalApplication);
    } else if (await canLaunchUrl(web)) {
      await launchUrl(web, mode: LaunchMode.externalApplication);
    }
  }

  bool get isMultiTtsInstalled => engines.contains(multiTtsEnginePackage);

  Future<void> speak(String text) async {
    if (!enabled.value) return;
    await _prepareForSpeak();
    isSessionActive.value = false;
    _chunks = const [];
    _chunkIndex = 0;
    sessionProgress.value = 0.0;
    lastSpokenText.value = text;
    final r = await _tts.speak(text);
    _handleSpeakResult(r);
  }

  Future<void> startChapter(String fullText, {String title = ''}) async {
    if (!enabled.value) return;
    await _prepareForSpeak();
    // 只折叠空白字符，保留 \n\n 段落分隔，供朗读时定位当前段落（阅读页高亮跟随）
    final cleaned = fullText.replaceAll(RegExp(r'[^\S\n]+'), ' ').trim();
    if (cleaned.isEmpty) return;

    _sessionGen++;
    final gen = _sessionGen;
    sessionTitle.value = title;
    isSessionActive.value = true;
    isPaused.value = false;

    final pairs = _splitToChunks(cleaned);
    _chunks = [for (final p in pairs) p.$1];
    _chunkParagraphs = [for (final p in pairs) p.$2];
    _chunkIndex = 0;
    sessionProgress.value = 0.0;
    currentChunkIndex.value = 0;
    currentChunkText.value = _chunks.isEmpty ? '' : _chunks.first;
    currentParagraphIndex.value = _chunkParagraphs.isEmpty ? -1 : _chunkParagraphs.first;

    lastSpokenText.value = cleaned;
    await _speakCurrentChunk(gen);
    _ensureSleepTimer();
  }

  Future<void> resumeSession() async {
    if (!enabled.value) return;
    await _prepareForSpeak();
    if (!isSessionActive.value) {
      if (lastSpokenText.value.trim().isNotEmpty) {
        await speak(lastSpokenText.value);
      }
      return;
    }
    if (isPaused.value) {
      final dynamic ttsDyn = _tts;
      try {
        isPaused.value = false;
        await ttsDyn.continueSpeaking();
        return;
      } catch (_) {
        try {
          isPaused.value = false;
          await ttsDyn.resume();
          return;
        } catch (_) {}
      }
    }
    isPaused.value = false;
    await _speakCurrentChunk();
  }

  Future<void> pauseSession() async {
    if (!enabled.value) return;
    _pauseRequested = true;
    _stopRequested = false;
    try {
      await _tts.pause();
    } catch (_) {
      try {
        await _tts.stop();
      } catch (_) {}
    }
    isPlaying.value = false;
    isPaused.value = true;
  }

  Future<void> pause() async {
    if (isSessionActive.value) {
      await pauseSession();
      return;
    }
    try {
      _pauseRequested = true;
      _stopRequested = false;
      await _tts.pause();
    } catch (_) {}
  }

  Future<void> stop() async {
    _stopRequested = true;
    _pauseRequested = false;
    try {
      await _tts.stop();
    } catch (_) {}
    _endSession();
  }

  Future<void> _speakCurrentChunk([int? gen]) async {
    if (!isSessionActive.value) return;
    if (gen != null && gen != _sessionGen) return;
    if (_chunkIndex < 0 || _chunkIndex >= _chunks.length) {
      await _onChapterFinished();
      return;
    }
    final chunk = _chunks[_chunkIndex];
    currentChunkIndex.value = _chunkIndex;
    currentChunkText.value = chunk;
    currentParagraphIndex.value = _chunkIndex < _chunkParagraphs.length ? _chunkParagraphs[_chunkIndex] : -1;
    try {
      final r = await _tts.speak(chunk);
      if (gen != null && gen != _sessionGen) return;
      _handleSpeakResult(r);
    } catch (_) {
      if (gen != null && gen != _sessionGen) return;
      _endSession();
      return;
    }
    sessionProgress.value = _chunks.isEmpty ? 0.0 : (_chunkIndex / _chunks.length).clamp(0.0, 1.0);
  }

  Future<void> _prepareForSpeak() async {
    try {
      await _tts.setSpeechRate(rate.value);
      await _tts.setPitch(pitch.value);
      await _tts.setVolume(volume.value);
    } catch (_) {}
    await _applyBestLanguage();
  }

  Future<void> _applyBestLanguage() async {
    final fromVoice = voice.value?['locale'];
    final deviceLocale = WidgetsBinding.instance.platformDispatcher.locale.toLanguageTag();

    final candidates = <String>{if (fromVoice != null && fromVoice.trim().isNotEmpty) fromVoice, deviceLocale, ..._preferredLocales}.toList();

    for (final loc in candidates) {
      if (await _trySetLanguage(loc)) {
        return;
      }
    }
  }

  Future<bool> _trySetLanguage(String locale) async {
    try {
      final available = await _tts.isLanguageAvailable(locale);
      if (available == null) {
        await _tts.setLanguage(locale);
        return true;
      }
      if (available is bool && !available) return false;
      await _tts.setLanguage(locale);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _handleSpeakResult(dynamic r) {
    if (r is int && r == 0) {
      if (_stopRequested || _pauseRequested) {
        Log.d("[TtsService] speak() returned 0 but stop/pause was requested; suppressing error");
        return;
      }

      Log.d("[TtsService] speak() returned 0 (failed)");

      isPlaying.value = false;
      isPaused.value = false;
      if (isSessionActive.value) {
        _endSession();
      }
      showSnackBar(message: "listen_to_books_failed_tip".tr, context: Get.context!);
    }
  }

  void _onChunkCompleted() {
    if (!isSessionActive.value) {
      isPlaying.value = false;
      isPaused.value = false;
      return;
    }
    if (isPaused.value) return;
    _chunkIndex += 1;
    if (_chunkIndex >= _chunks.length) {
      _onChapterFinished();
      return;
    }
    _speakCurrentChunk(_sessionGen);
  }

  /// 本章读完：连播下一章或正常结束
  Future<void> _onChapterFinished() async {
    if (autoNextChapter.value && onChapterComplete != null) {
      try {
        await onChapterComplete!();
        return;
      } catch (e) {
        Log.d("[TtsService] autoNextChapter failed: $e");
      }
    }
    _endSession();
  }

  /// 跳到上一句
  Future<void> previousChunk() async {
    if (!isSessionActive.value || _chunks.isEmpty) return;
    _chunkIndex = (_chunkIndex - 1).clamp(0, _chunks.length - 1);
    _pauseRequested = false;
    try {
      await _tts.stop();
    } catch (_) {}
    await _speakCurrentChunk(_sessionGen);
  }

  /// 跳到下一句
  Future<void> nextChunk() async {
    if (!isSessionActive.value || _chunks.isEmpty) return;
    _chunkIndex = (_chunkIndex + 1).clamp(0, _chunks.length - 1);
    _pauseRequested = false;
    try {
      await _tts.stop();
    } catch (_) {}
    if (_chunkIndex >= _chunks.length) {
      await _onChapterFinished();
      return;
    }
    await _speakCurrentChunk(_sessionGen);
  }

  /// 设置睡眠定时（分钟；0 取消）
  Future<void> setSleepTimer(int minutes) async {
    sleepMinutes.value = minutes;
    _sleepTimer?.cancel();
    _sleepTimer = null;
    sleepRemaining.value = minutes;
    if (minutes <= 0) return;
    _sleepTimer = Timer.periodic(const Duration(minutes: 1), (t) async {
      sleepRemaining.value -= 1;
      if (sleepRemaining.value <= 0) {
        t.cancel();
        _sleepTimer = null;
        sleepMinutes.value = 0;
        await stop();
      }
    });
  }

  void _ensureSleepTimer() {
    // 已有定时则保持；未设置则不动
    if (sleepMinutes.value > 0 && _sleepTimer == null) {
      setSleepTimer(sleepMinutes.value);
    }
  }

  void _endSession() {
    _sessionGen++;
    isSessionActive.value = false;
    isPlaying.value = false;
    isPaused.value = false;
    _chunks = const [];
    _chunkParagraphs = const [];
    _chunkIndex = 0;
    sessionProgress.value = 0.0;
    currentChunkIndex.value = -1;
    currentChunkText.value = '';
    currentParagraphIndex.value = -1;
    _sleepTimer?.cancel();
    _sleepTimer = null;
    sleepRemaining.value = 0;
  }

  /// 按段落切分：先按 \n\n 拆段，再在段内按句读切句块，句块归属其所在段落。
  /// 返回 (句块文本, 段落索引) 列表，供阅读页高亮当前朗读段落。
  List<(String, int)> _splitToChunks(String text) {
    final paragraphs = text.split('\n\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

    final chunks = <(String, int)>[];
    for (var pi = 0; pi < paragraphs.length; pi++) {
      final para = paragraphs[pi];
      final parts = para.split(RegExp(r'(?<=[。！？!?；;])')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      final buf = StringBuffer();
      void flush() {
        if (buf.isNotEmpty) {
          chunks.add((buf.toString(), pi));
          buf.clear();
        }
      }

      for (final p in parts.isEmpty ? [para] : parts) {
        if (buf.length + p.length <= _maxChunkLen) {
          buf.write(p);
        } else {
          flush();
          if (p.length <= _maxChunkLen) {
            buf.write(p);
          } else {
            for (var i = 0; i < p.length; i += _maxChunkLen) {
              chunks.add((p.substring(i, (i + _maxChunkLen).clamp(0, p.length)), pi));
            }
          }
        }
      }
      flush();
    }
    return chunks;
  }
}
