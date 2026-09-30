import 'dart:io';
import 'package:enough_convert/enough_convert.dart';
import 'package:get/get.dart';
import 'package:hikari_novel_flutter/network/browser_client.dart';
import 'package:hikari_novel_flutter/service/api_service.dart';
import 'package:path_provider/path_provider.dart';

import '../common/log.dart';
import '../models/common/charset_type.dart';
import '../models/common/wenku8_node.dart';

class ChapterDownloaderService extends GetxService {
  // 取消标记：taskId -> true
  final Map<String, bool> _cancelFlags = {};

  // 下载状态：taskId -> true (下载中)
  final Map<String, bool> _downloadingStatus = {};

  void cancel(String taskId) {
    if (_downloadingStatus.containsKey(taskId)) {
      _cancelFlags[taskId] = true;
      Log.i('任务 $taskId 已请求取消');
    }
    _downloadingStatus.remove(taskId);
  }

  void clearCancel(String taskId) {
    _cancelFlags.remove(taskId);
    _downloadingStatus.remove(taskId);
  }

  bool isDownloading(String taskId) => _downloadingStatus[taskId] ?? false;

  bool isCanceled(String taskId) => _cancelFlags[taskId] == true;

  Future<String> download({
    required String taskId,
    required String aid,
    required String cid,
    Function(int received, int total)? onProgress,
  }) async {
    if (isDownloading(taskId)) {
      throw Exception('任务 $taskId 正在下载中，请勿重复下载');
    }
    if (isCanceled(taskId)) {
      throw Exception('任务 $taskId 已被取消');
    }

    _downloadingStatus[taskId] = true;
    _cancelFlags[taskId] = false;

    try {
      final dir = await getApplicationSupportDirectory();
      final cacheDir = Directory("${dir.path}/cached_chapter");
      if (!(await cacheDir.exists())) {
        await cacheDir.create(recursive: true);
      }
      final savePath = "${cacheDir.path}/${aid}_$cid.txt";

      final charset = switch (ApiService.instance.charsetType) {
        CharsetType.gbk => "gbk",
        CharsetType.big5Hkscs => "big5",
      };
      final url = "${ApiService.instance.wenku8Node.node}/modules/article/reader.php?aid=$aid&cid=$cid&charset=$charset";

      Log.d("$url ${ApiService.instance.charsetType.name}");

      final res = await BrowserClient.fetch(url);

      if (_cancelFlags[taskId] == true) {
        throw Exception('canceled');
      }

      if (res.statusCode == 403) {
        throw Exception('Cloudflare blocked');
      }

      final String content = switch (ApiService.instance.charsetType) {
        CharsetType.gbk => GbkDecoder().convert(res.body),
        CharsetType.big5Hkscs => Big5Decoder().convert(res.body),
      };

      onProgress?.call(res.body.length, res.body.length);

      final file = File(savePath);
      await file.writeAsString(content, flush: true);

      Log.i('章节 $aid-$cid 下载完成，保存路径：$savePath');
      return savePath;
    } catch (e) {
      if (e.toString().contains('canceled')) {
        Log.e('任务 $taskId 被取消');
        rethrow;
      }
      Log.e('任务 $taskId 处理失败: $e');
      rethrow;
    } finally {
      _downloadingStatus.remove(taskId);
      _cancelFlags.remove(taskId);
    }
  }

  void cancelAll() {
    for (final id in _downloadingStatus.keys.toList()) {
      cancel(id);
    }
    _cancelFlags.clear();
    _downloadingStatus.clear();
  }

  void dispose() {
    cancelAll();
  }
}
