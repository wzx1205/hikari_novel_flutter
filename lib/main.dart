import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:get/get.dart';
import 'package:hikari_novel_flutter/common/app_translations.dart';
import 'package:hikari_novel_flutter/common/constants.dart';
import 'package:hikari_novel_flutter/common/util.dart';
import 'package:hikari_novel_flutter/network/request.dart';
import 'package:hikari_novel_flutter/router/app_pages.dart';
import 'package:hikari_novel_flutter/router/route_path.dart';
import 'package:hikari_novel_flutter/service/db_service.dart';
import 'package:hikari_novel_flutter/service/dev_mode_service.dart';
import 'package:hikari_novel_flutter/service/local_storage_service.dart';
import 'package:hikari_novel_flutter/service/tts_service.dart';
import 'package:jiffy/jiffy.dart';

final localhostServer = InAppLocalhostServer(documentRoot: 'assets');
WebViewEnvironment? webViewEnvironment;

void main() async {
  WidgetsBinding widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

  try {
    await Get.put(LocalStorageService()).init();
    Get.put(DevModeService()).init();
    Get.put(DBService()).init();
    await Get.put(TtsService()).init();

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      final availableVersion = await WebViewEnvironment.getAvailableVersion();
      assert(availableVersion != null, 'Failed to find an installed WebView2 runtime or non-stable Microsoft Edge installation.');
      webViewEnvironment = await WebViewEnvironment.create(settings: WebViewEnvironmentSettings(userDataFolder: 'custom_path'));
    } else if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      await InAppWebViewController.setWebContentsDebuggingEnabled(kDebugMode);
    }

    _init();
    await Jiffy.setLocale(Util.getCurrentLocale().toString());
    Request.initCookie(); //初始化 cookie
  } catch (e) {
    print('Initialization error: $e');
  } finally {
    FlutterNativeSplash.remove();
  }

  runApp(const MyApp());
}
