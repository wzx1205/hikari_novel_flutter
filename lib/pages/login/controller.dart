import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:hikari_novel_flutter/main.dart';
import 'package:hikari_novel_flutter/models/page_state.dart';
import 'package:hikari_novel_flutter/common/constants.dart';
import 'package:hikari_novel_flutter/router/route_path.dart';
import 'package:hikari_novel_flutter/service/api_service.dart';

import '../../common/database/database.dart';
import '../../models/resource.dart';
import '../../parser/parser.dart';
import '../../service/db_service.dart';
import '../../service/local_storage_service.dart';

class LoginController extends GetxController {
  RxBool showLoading = true.obs;
  RxInt loadingProgress = 0.obs;
  final CookieManager cookieManager = CookieManager.instance(webViewEnvironment: webViewEnvironment);
  InAppWebViewController? inAppWebViewController;
  final GlobalKey webViewKey = GlobalKey();
  final InAppWebViewSettings settings = InAppWebViewSettings(isInspectable: kDebugMode, userAgent: kUserAgent["User-Agent"], javaScriptEnabled: true);
  RxString currentUrl = "".obs;

  Rx<PageState> pageState = PageState.success.obs;
  String errorMsg = "";

  String get url => "${ApiService.instance.wenku8Node.node}/login.php";

  @override
  void onInit() {
    super.onInit();
    cookieManager.deleteAllCookies();
  }

  Future<void> saveCookie(InAppWebViewController webController, WebUri uri) async {
    showLoading.value = false;

    //存储cookie（含 CF Worker 中继域名）
    final uriStr = uri.toString();
    if (!(uriStr.contains("wenku8") || uriStr.contains("zuohe233.work") || uriStr.contains("workers.dev"))) {
      return;
    }

    // 优先用 JS 读 document.cookie；失败再走 CookieManager（可拿到 HttpOnly 的 cf_clearance）
    String cookiesJs = "";
    try {
      cookiesJs = (await webController.evaluateJavascript(source: "document.cookie")).toString();
    } catch (_) {
      cookiesJs = "";
    }

    final cookieMap = _parseCookieString(cookiesJs);
    if (cookieMap.containsKey('jieqiUserInfo') && cookieMap.containsKey('jieqiVisitInfo')) {
      await _onLoginSuccess(_buildCookieHeader(cookieMap));
      return;
    }

    final getCookie = await cookieManager.getCookies(url: uri);
    final hasCookie = ["jieqiUserInfo", "jieqiVisitInfo"].every(
      (keyword) => getCookie.any((cookieItem) => cookieItem.name.contains(keyword)),
    );
    if (!hasCookie) return;

    final fromManager = <String, String>{
      for (final c in getCookie) c.name: c.value,
    };
    await _onLoginSuccess(_buildCookieHeader(fromManager));
  }

  Map<String, String> _parseCookieString(String cookiesJs) {
    final cookieMap = <String, String>{};
    for (final part in cookiesJs.split(';')) {
      final trimmed = part.trim();
      final eq = trimmed.indexOf('=');
      if (eq > 0) {
        cookieMap[trimmed.substring(0, eq)] = trimmed.substring(eq + 1);
      }
    }
    return cookieMap;
  }

  String _buildCookieHeader(Map<String, String> map) {
    String cookie = "jieqiUserInfo=${map['jieqiUserInfo']};";
    cookie += "jieqiVisitInfo=${map['jieqiVisitInfo']}";
    final cfClearance = map['cf_clearance'];
    if (cfClearance != null && cfClearance.isNotEmpty) {
      cookie += ";cf_clearance=$cfClearance";
    }
    return cookie;
  }

  Future<void> _onLoginSuccess(String cookie) async {
    LocalStorageService.instance.setCookie(cookie);
    ApiService.instance.initCookie();

    try {
      await _getUserInfo();
      await _refreshBookshelf();
    } catch (e) {
      LocalStorageService.instance.setCookie(null); //清空cookie
      ApiService.instance.deleteCookie();

      final controller = inAppWebViewController;
      if (controller != null) {
        inAppWebViewController = null;
        controller.dispose(); //销毁webview，停止加载网页
      }

      errorMsg = e.toString();
      pageState.value = PageState.error;
      return;
    }

    Get.offAllNamed(RoutePath.main);
  }

  Future<void> _getUserInfo() async {
    final data = await ApiService.instance.getUserInfo();
    switch (data) {
      case Success():
        LocalStorageService.instance.setUserInfo(Parser.getUserInfo(data.data));
      case Error():
        {
          throw data.error;
        }
    }
  }

  Future<void> _refreshBookshelf() async {
    await DBService.instance.deleteAllBookshelf();

    final futures = Iterable.generate(6, (index) async {
      await _insertAll(index);
    });
    await Future.wait(futures);
  }

  Future<void> _insertAll(int index) async {
    final result = await ApiService.instance.getBookshelf(classId: index);
    switch (result) {
      case Success():
        {
          final bookshelf = Parser.getBookshelf(result.data, index);
          if (bookshelf.list.isNotEmpty) {
            final insertData = bookshelf.list.map((e) {
              return BookshelfEntityData(aid: e.aid, bid: e.bid, url: e.url, title: e.title, img: e.img, classId: bookshelf.classId.toString());
            });
            await DBService.instance.insertAllBookshelf(insertData);
          }
        }
      case Error():
        {
          throw result.error;
        }
    }
  }
}
