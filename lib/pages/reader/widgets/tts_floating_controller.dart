import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../common/constants.dart';
import '../../../service/tts_service.dart';
import '../controller.dart';

class TtsFloatingController extends StatefulWidget {
  const TtsFloatingController({super.key});

  @override
  State<TtsFloatingController> createState() => _TtsFloatingControllerState();
}

class _TtsFloatingControllerState extends State<TtsFloatingController> {
  Offset offset = const Offset(16, 180);

  @override
  Widget build(BuildContext context) {
    final tts = TtsService.instance;
    final reader = Get.find<ReaderController>();

    return Obx(() {
      final visible = tts.enabled.value && (tts.isPlaying.value || tts.isPaused.value);
      if (!visible) return const SizedBox.shrink();

      final size = MediaQuery.of(context).size;
      final safeTop = MediaQuery.of(context).padding.top + 8;
      final safeBottom = MediaQuery.of(context).padding.bottom + 8;
      final clamped = Offset(offset.dx.clamp(8, size.width - 8 - 320), offset.dy.clamp(safeTop, size.height - safeBottom - 56));
      offset = clamped;

      return Positioned(
        left: offset.dx,
        top: offset.dy,
        child: Draggable(
          feedback: _buildCard(context, tts, reader, dragging: true),
          childWhenDragging: const SizedBox.shrink(),
          onDragEnd: (details) {
            setState(() => offset = details.offset);
          },
          child: _buildCard(context, tts, reader),
        ),
      );
    });
  }

  Widget _buildCard(BuildContext context, TtsService tts, ReaderController reader, {bool dragging = false}) {
    final theme = Theme.of(context);
    final bg = theme.colorScheme.surface;
    final fg = theme.colorScheme.onSurface;

    return Material(
      color: Colors.transparent,
      elevation: dragging ? 8 : 4,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 320,
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: theme.dividerColor.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            Icon(Icons.record_voice_over_outlined, color: fg.withValues(alpha: 0.75), size: 20),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tts.sessionTitle.value.isEmpty ? "listen_to_books".tr : tts.sessionTitle.value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: kBaseTileSubtitleTextStyle.copyWith(color: fg),
                  ),
                  Text(
                    tts.sleepRemaining.value > 0
                        ? "${tts.sleepRemaining.value} min"
                        : (tts.currentChunkText.value.isEmpty ? "listen_to_books".tr : tts.currentChunkText.value),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: kBaseTileSubtitleTextStyle.copyWith(color: fg.withValues(alpha: 0.6), fontSize: 10),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: "上一句",
              iconSize: 20,
              onPressed: tts.isSessionActive.value ? () => tts.previousChunk() : null,
              icon: const Icon(Icons.skip_previous_outlined),
            ),
            IconButton(
              tooltip: tts.isPlaying.value ? "pause".tr : "play".tr,
              iconSize: 22,
              onPressed: () async {
                if (tts.isPlaying.value) {
                  await tts.pauseSession();
                } else if (tts.isPaused.value && tts.isSessionActive.value) {
                  await tts.resumeSession();
                } else {
                  // 保留 \n\n 段落分隔：TTS 依赖它定位当前朗读段落（阅读页高亮跟随）
                  final cleaned = reader.text.value.trim();
                  if (cleaned.isNotEmpty) {
                    tts.autoNextChapter.value = true;
                    tts.onChapterComplete = () async {
                      reader.nextChapter();
                      await Future.delayed(const Duration(milliseconds: 400));
                      final nextText = reader.text.value.trim();
                      if (nextText.isNotEmpty) {
                        await tts.startChapter(nextText, title: reader.chapterTitle.value);
                      }
                    };
                    await tts.startChapter(cleaned, title: reader.chapterTitle.value);
                  }
                }
              },
              icon: Icon(tts.isPlaying.value ? Icons.pause_circle_outline : Icons.play_circle_outline),
            ),
            IconButton(
              tooltip: "下一句",
              iconSize: 20,
              onPressed: tts.isSessionActive.value ? () => tts.nextChunk() : null,
              icon: const Icon(Icons.skip_next_outlined),
            ),
            PopupMenuButton<int>(
              tooltip: "定时关闭",
              iconSize: 20,
              icon: const Icon(Icons.timer_outlined),
              onSelected: (m) => tts.setSleepTimer(m),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 0, child: Text("关闭定时")),
                PopupMenuItem(value: 15, child: Text("15 分钟")),
                PopupMenuItem(value: 30, child: Text("30 分钟")),
                PopupMenuItem(value: 60, child: Text("60 分钟")),
              ],
            ),
            IconButton(tooltip: "stop".tr, iconSize: 22, onPressed: () => tts.stop(), icon: const Icon(Icons.stop_circle_outlined)),
          ],
        ),
      ),
    );
  }
}
