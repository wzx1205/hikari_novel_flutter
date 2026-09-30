import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:hikari_novel_flutter/main.dart';
import 'package:hikari_novel_flutter/models/common/wenku8_node.dart';
import 'package:hikari_novel_flutter/models/page_state.dart';
import 'package:hikari_novel_flutter/router/route_path.dart';
import 'package:hikari_novel_flutter/service/api_service.dart';

import '../../common/database/database.dart';
import '../../common/log.dart';
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
  final InAppWebViewSettings settings = InAppWebViewSettings(
    isInspectable: kDebugMode,
    // 与 iOS scripting 同款 iPhone UA，降低 CF 对登录 POST 的拦截概率
    userAgent:
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
    javaScriptEnabled: true,
    mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
  );
  RxString currentUrl = "".obs;
  RxBool submitting = false.obs;

  Rx<PageState> pageState = PageState.success.obs;
  String errorMsg = "";

  String get url => "${ApiService.instance.wenku8Node.node}/login.php";

  @override
  void onInit() {
    super.onInit();
    cookieManager.deleteAllCookies();
  }

  /// 走 BrowserClient 的登录（scripting 同款：POST do=login）
  Future<void> doProgrammaticLogin(String user, String pass, {int useCookieSeconds = 31536000}) async {
    if (submitting.value) return;
    if (user.isEmpty || pass.isEmpty) {
      errorMsg = "please_input_username".tr;
      pageState.value = PageState.error;
      return;
    }
    submitting.value = true;
    showLoading.value = true;
    try {
      Log.d("[login] submit via BrowserClient user=$user usecookie=$useCookieSeconds");
      final result = await ApiService.instance.login(user, pass, useCookieSeconds: useCookieSeconds);
      if (!result.success) {
        errorMsg = result.message;
        pageState.value = PageState.error;
        return;
      }

      final map = await _collectSessionCookies();
      Log.d("[login] cookie names=${map.keys.toList()}");
      if (!map.containsKey('jieqiUserInfo') || !map.containsKey('jieqiVisitInfo')) {
        Log.d("[login] missing session cookie after XHR login");
        errorMsg = "login_cookie_missing_tip".tr;
        pageState.value = PageState.error;
        return;
      }
      await _onLoginSuccess(_buildCookieHeader(map));
    } catch (e) {
      Log.d("[login] error $e");
      errorMsg = e.toString();
      pageState.value = PageState.error;
    } finally {
      submitting.value = false;
      showLoading.value = false;
    }
  }

  /// 从 WebView CookieManager 收集会话 Cookie。
  /// wenku8 可能落在 http:// 源，http/https 都要查。
  Future<Map<String, String>> _collectSessionCookies() async {
    final map = <String, String>{};
    final node = ApiService.instance.wenku8Node.node;
    final host = Uri.parse(node).host;
    final probeUrls = <String>[
      'http://$host/',
      'https://$host/',
      node,
      'http://www.wenku8.net/',
      'https://www.wenku8.net/',
      'http://www.wenku8.cc/',
      'https://www.wenku8.cc/',
    ];
    for (final u in probeUrls) {
      try {
        final cookies = await cookieManager.getCookies(url: WebUri(u));
        for (final c in cookies) {
          if (c.name.isNotEmpty && c.value.isNotEmpty) map[c.name] = c.value;
        }
      } catch (_) {}
    }
    if (!map.containsKey('jieqiUserInfo') || !map.containsKey('jieqiVisitInfo')) {
      try {
        final js = (await inAppWebViewController?.evaluateJavascript(source: 'document.cookie'))?.toString() ?? '';
        for (final part in js.split(';')) {
          final t = part.trim();
          final eq = t.indexOf('=');
          if (eq > 0) map[t.substring(0, eq)] = t.substring(eq + 1);
        }
      } catch (_) {}
    }
    return map;
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
    } catch (e) {
      LocalStorageService.instance.setCookie(null);
      ApiService.instance.deleteCookie();

      final controller = inAppWebViewController;
      if (controller != null) {
        inAppWebViewController = null;
        controller.dispose();
      }

      errorMsg = e.toString();
      pageState.value = PageState.error;
      return;
    }

    // 书架后台补拉，失败不阻断登录
    unawaited(() async {
      try {
        await _refreshBookshelf();
      } catch (e) {
        Log.d("[login] refreshBookshelf failed: $e");
      }
    }());

    Get.offAllNamed(RoutePath.main);
  }

  Future<void> _getUserInfo() async {
    final data = await ApiService.instance.getUserInfo();
    switch (data) {
      case Success():
        try {
          LocalStorageService.instance.setUserInfo(Parser.getUserInfo(data.data));
        } catch (e) {
          // 解析失败不阻断登录（cookie 已就绪）
          Log.d("[login] parse user info failed: $e");
        }
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
