import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:hikari_novel_flutter/main.dart';
import 'package:hikari_novel_flutter/models/common/wenku8_node.dart';
import 'package:hikari_novel_flutter/models/page_state.dart';
import 'package:hikari_novel_flutter/network/request.dart';
import 'package:hikari_novel_flutter/router/route_path.dart';

import '../../common/database/database.dart';
import '../../models/resource.dart';
import '../../network/api.dart';
import '../../network/parser.dart';
import '../../service/db_service.dart';
import '../../service/local_storage_service.dart';

class LoginController extends GetxController {
  RxBool showLoading = true.obs;
  RxInt loadingProgress = 0.obs;
  final CookieManager cookieManager = CookieManager.instance(webViewEnvironment: webViewEnvironment);
  InAppWebViewController? inAppWebViewController;
  final GlobalKey webViewKey = GlobalKey();
  final InAppWebViewSettings settings = InAppWebViewSettings(
    isInspectable: kDebugMode,
    userAgent: Request.userAgent[HttpHeaders.userAgentHeader],
    javaScriptEnabled: true,
  );
  RxString currentUrl = "".obs;

  Rx<PageState> pageState = PageState.success.obs;
  String errorMsg = "";

  String get url => "${Api.wenku8Node.node}/login.php";

  @override
  void onInit() {
    super.onInit();
    cookieManager.deleteAllCookies();
  }

  Future<void> saveCookie(InAppWebViewController webController, WebUri uri) async {
    showLoading.value = false;

    //存储cookie
    if (uri.toString().contains("wenku8") == true || uri.toString().contains("zuohe233.work") == true) {
      // 使用 JS 从 WebView 内部读取 document.cookie，比 CookieManager API 更可靠
      String cookiesJs;
      try {
        cookiesJs = (await webController.evaluateJavascript(source: "document.cookie")).toString();
      } catch (_) {
        // fallback to CookieManager API
        final getCookie = await cookieManager.getCookies(url: uri);
        final hasCookie = ["jieqiUserInfo", "jieqiVisitInfo"].every(
          (keyword) => getCookie.any((cookieItem) => cookieItem.name.contains(keyword)),
        );
        if (hasCookie) {
          String cookie = "jieqiUserInfo=${getCookie.firstWhere((cookieItem) => cookieItem.name == "jieqiUserInfo").value};";
          cookie += "jieqiVisitInfo=${getCookie.firstWhere((cookieItem) => cookieItem.name == "jieqiVisitInfo").value}";
          final cfClearance = getCookie.firstWhere(
            (c) => c.name == "cf_clearance",
            orElse: () => Cookie(name: "cf_clearance", value: ""),
          );
          if (cfClearance.value.isNotEmpty) {
            cookie += ";cf_clearance=${cfClearance.value}";
          }
          await _onLoginSuccess(cookie);
          return;
        }
        return;
      }

      // 从 document.cookie 字符串中解析所需 cookie
      final cookieMap = <String, String>{};
      for (final part in cookiesJs.split(';')) {
        final trimmed = part.trim();
        final eq = trimmed.indexOf('=');
        if (eq > 0) {
          cookieMap[trimmed.substring(0, eq)] = trimmed.substring(eq + 1);
        }
      }

      final hasCookie = cookieMap.containsKey('jieqiUserInfo') && cookieMap.containsKey('jieqiVisitInfo');
      if (hasCookie) {
        String cookie = "jieqiUserInfo=${cookieMap['jieqiUserInfo']};";
        cookie += "jieqiVisitInfo=${cookieMap['jieqiVisitInfo']}";
        final cfClearance = cookieMap['cf_clearance'];
        if (cfClearance != null && cfClearance.isNotEmpty) {
          cookie += ";cf_clearance=$cfClearance";
        }
        await _onLoginSuccess(cookie);
      }
    }
  }

  Future<void> _onLoginSuccess(String cookie) async {
    LocalStorageService.instance.setCookie(cookie);
    Request.initCookie();

    try {
      await _getUserInfo();
      await _refreshBookshelf();
    } catch (e) {
      LocalStorageService.instance.setCookie(null); //清空cookie
      Request.deleteCookie();

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
    final data = await Api.getUserInfo();
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
    final result = await Api.getBookshelf(classId: index);
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
