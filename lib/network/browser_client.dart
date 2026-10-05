import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hikari_novel_flutter/models/common/wenku8_node.dart';

import '../common/log.dart';
import '../main.dart' show webViewEnvironment;
import '../service/local_storage_service.dart';

/// WebView fetch 传输层。
///
/// Cloudflare 的 cf_clearance / 挑战与 TLS 指纹绑定：Dio(dart:io) 的指纹过不了盾，
/// WebView（系统浏览器内核）可以。所有 wenku8 请求统一走 WebView 内的 fetch，
/// 与登录页同一 TLS 栈，从而不再被 CF 拦。
///
/// WebView 初始页跟随所选节点（wenku8.net / wenku8.cc / CF Worker 中继）加载，
/// 请求 JS 里的同源改写会把目标 URL 对齐到页面所在源，因此节点切换后必须重建
/// WebView，否则请求会被劫持回旧节点域名。
///
/// 所有请求经全局队列串行执行并保持最小间隔，避免突发并发触发 CF 限流封 IP。
class BrowserClient {
  BrowserClient._();

  static HeadlessInAppWebView? _webview;
  static Future<void>? _initFuture;
  static int _reqSeq = 0;

  /// 当前 WebView 页面所在的节点 base（如 https://www.wenku8.net）
  static String? _pageBase;

  /// 请求串行队列 + 相邻请求最小间隔
  static Future<void> _queue = Future.value();
  static const Duration _minRequestInterval = Duration(milliseconds: 350);

  /// 会员页（书架等）专用 WebView：文库 CF 拦会员路径的 XHR 式请求、放行真导航，
  /// 因此会员页用「真导航 + 抓取 outerHTML」获取。固定直连 wenku8.net——
  /// 经 Worker 中继的导航也会被上游按数据中心来源拦掉。cookie 与主 WebView 共享。
  static HeadlessInAppWebView? _memberWebview;
  static Future<void>? _memberInitFuture;
  static Completer<void>? _memberNavCompleter;

  static Future<void> _syncNode(String base) async {
    if (_pageBase == base) return;
    Log.d('BrowserClient: node switch ${_pageBase ?? '(none)'} -> $base, rebuilding webview');
    _pageBase = base;
    _initFuture = null;
    final old = _webview;
    _webview = null;
    _pending.clear();
    if (old != null) {
      try {
        await old.dispose();
      } catch (_) {}
    }
  }

  static Future<void> _ensureReady() async {
    await _syncNode(LocalStorageService.instance.getWenku8Node().node);
    _initFuture ??= _init(_pageBase!);
    await _initFuture;
  }

  static Future<void> _init(String base) async {
    final ready = Completer<void>();
    final wv = HeadlessInAppWebView(
      webViewEnvironment: webViewEnvironment,
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        useShouldOverrideUrlLoading: false,
        mediaPlaybackRequiresUserGesture: false,
        transparentBackground: true,
        javaScriptCanOpenWindowsAutomatically: true,
        // wenku8 存在 https→http 跳转，必须放行混合内容
        mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
        useShouldInterceptAjaxRequest: false,
      ),
      // 必须从目标源加载页面，否则 about:blank 跨源 fetch 会被浏览器拒绝
      // 用页面导航而不是 XHR：这样 CF Turnstile/JS 盾才能在 WebView 里跑完
      // Worker 中继域名下 index.php 会被反向代理到 wenku8 首页，同样可用
      initialUrlRequest: URLRequest(url: WebUri('$base/index.php')),
      onLoadStop: (controller, url) {
        if (!ready.isCompleted) ready.complete();
      },
    );
    _webview = wv;
    await wv.run();
    await ready.future.timeout(const Duration(seconds: 8), onTimeout: () {
      Log.w('BrowserClient: onLoadStop timeout, continue anyway');
    });

    // 注册回调通道
    wv.webViewController?.addJavaScriptHandler(
      handlerName: 'browserClientCb',
      callback: (args) {
        final id = args.isNotEmpty && args[0] is Map ? (args[0] as Map)['id'] : null;
        final c = _pending[id];
        if (c != null && !c.isCompleted) {
          c.complete(args.isNotEmpty ? args[0] : null);
        }
      },
    );

    // ping 确认 JS 桥可用
    for (var i = 0; i < 30; i++) {
      try {
        final ok = await wv.webViewController?.evaluateJavascript(source: '1+1');
        Log.d('BrowserClient: js ping = $ok');
        if (ok != null) break;
      } catch (e) {
        Log.d('BrowserClient: js ping fail $e');
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }

    // 等 CF 盾自动解开（XHR 打到挑战页是 403，导航却可以解）
    await _waitForChallengeClear(webview: wv, timeout: const Duration(seconds: 20));
  }

  /// 会员页专用 WebView 初始化（固定直连 wenku8.net）
  static Future<void> _initMember() async {
    final ready = Completer<void>();
    final wv = HeadlessInAppWebView(
      webViewEnvironment: webViewEnvironment,
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        useShouldOverrideUrlLoading: false,
        mediaPlaybackRequiresUserGesture: false,
        transparentBackground: true,
        javaScriptCanOpenWindowsAutomatically: true,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
        useShouldInterceptAjaxRequest: false,
        loadsImagesAutomatically: false,
      ),
      initialUrlRequest: URLRequest(url: WebUri('https://www.wenku8.net/index.php')),
      onLoadStop: (controller, url) {
        if (!ready.isCompleted) ready.complete();
        if (_memberNavCompleter != null && !_memberNavCompleter!.isCompleted) {
          _memberNavCompleter!.complete();
        }
      },
    );
    _memberWebview = wv;
    await wv.run();
    await ready.future.timeout(const Duration(seconds: 8), onTimeout: () {
      Log.w('BrowserClient: member webview onLoadStop timeout, continue anyway');
    });
    await _waitForChallengeClear(webview: wv, timeout: const Duration(seconds: 20));
  }

  static Future<void> _ensureMemberReady() => _memberInitFuture ??= _initMember();

  /// 会员页抓取：WebView 真导航 + 抓 outerHTML。
  ///
  /// 文库 CF 对 bookcase.php 等会员路径拦一切 XHR 式请求（同 IP 实测：浏览器
  /// 导航可达、XHR 必 403），只能走导航。返回体是浏览器解码后的 UTF-8 文本，
  /// 调用方无需再做 GBK 解码。走全局串行队列，与 XHR 共享限速节奏。
  static Future<BrowserResponse> navigateFetch(
    String url, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    return _runSerialized(() => _navigateFetch(url, timeout: timeout));
  }

  static Future<BrowserResponse> _navigateFetch(
    String url, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    await _ensureMemberReady();
    final controller = _memberWebview?.webViewController;
    if (controller == null) {
      throw StateError('BrowserClient member WebView not ready');
    }

    final nav = Completer<void>();
    _memberNavCompleter = nav;
    try {
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    } catch (e) {
      _memberNavCompleter = null;
      Log.e('BrowserClient: navigate loadUrl failed: $e');
      rethrow;
    }
    try {
      await nav.future.timeout(timeout, onTimeout: () {
        Log.w('BrowserClient: nav onLoadStop timeout, continue anyway');
      });
    } finally {
      _memberNavCompleter = null;
    }

    // 等 readyState 完成且不在 CF 挑战页
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final title = (await controller.getTitle())?.toLowerCase() ?? '';
        final readyState =
            (await controller.evaluateJavascript(source: 'document.readyState'))?.toString().replaceAll('"', '') ?? '';
        if (readyState == 'complete' && title.isNotEmpty && !_isChallengeTitle(title) && !title.contains('moment')) {
          break;
        }
      } catch (e) {
        Log.d('BrowserClient: nav poll fail $e');
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }

    final html =
        (await controller.evaluateJavascript(source: 'document.documentElement.outerHTML'))?.toString() ?? '';
    final currentUrl = (await controller.getUrl())?.toString() ?? url;
    Log.d('BrowserClient: nav scrape bytes=${html.length} url=$currentUrl');
    return BrowserResponse(
      statusCode: 200,
      url: currentUrl,
      body: utf8.encode(html),
    );
  }

  /// 轮询当前页是否已过 CF 盾。挑战页标题一般是 Just a moment / 请稍候 / Attention Required
  static Future<void> _waitForChallengeClear({
    HeadlessInAppWebView? webview,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final wv = webview ?? _webview;
    final deadline = DateTime.now().add(timeout);
    var reloaded = false;
    while (DateTime.now().isBefore(deadline)) {
      try {
        final title = await wv?.webViewController?.getTitle();
        final t = title?.toLowerCase() ?? '';
        Log.d('BrowserClient: page title=$title');
        final challenged = _isChallengeTitle(t);
        if (!challenged && t.isNotEmpty && !t.contains('moment')) {
          Log.d('BrowserClient: challenge cleared');
          return;
        }
      } catch (e) {
        Log.d('BrowserClient: title read fail $e');
      }
      // 卡住则刷新一次再等
      if (!reloaded && DateTime.now().isAfter(deadline.subtract(Duration(seconds: timeout.inSeconds * 2 ~/ 3)))) {
        reloaded = true;
        Log.w('BrowserClient: challenge stuck, reloading');
        try {
          await wv?.webViewController?.reload();
        } catch (_) {}
      }
      await Future.delayed(const Duration(milliseconds: 800));
    }
    Log.w('BrowserClient: challenge not cleared in time (continue anyway)');
  }

  static bool _isChallengeTitle(String t) {
    return t.contains('just a moment') ||
        t.contains('attention required') ||
        t.contains('checking your browser') ||
        t.contains('please wait') ||
        t.contains('请稍候') ||
        t.contains('请稍等') ||
        t.contains('验证');
  }

  /// 公开：确保 WebView 就绪且 CF 盾已过（登录前调用）
  static Future<void> ensureChallengeCleared({Duration timeout = const Duration(seconds: 15)}) async {
    await _ensureReady();
    return _waitForChallengeClear(timeout: timeout);
  }

  static final Map<dynamic, Completer<dynamic>> _pending = {};

  static Future<void> dispose() async {
    final wv = _webview;
    final mwv = _memberWebview;
    _webview = null;
    _memberWebview = null;
    _initFuture = null;
    _memberInitFuture = null;
    _pageBase = null;
    _pending.clear();
    for (final v in [wv, mwv]) {
      try {
        await v?.dispose();
      } catch (_) {}
    }
  }

  /// 公开入口：全局串行队列，请求之间保持最小间隔，防止突发并发触发 CF 限流
  static Future<BrowserResponse> fetch(
    String url, {
    String method = 'GET',
    Map<String, String>? headers,
    List<int>? body,
    Duration timeout = const Duration(seconds: 25),
  }) {
    return _runSerialized(
      () => _fetch(url, method: method, headers: headers, body: body, timeout: timeout),
    );
  }

  static Future<T> _runSerialized<T>(Future<T> Function() task) {
    final prev = _queue;
    final gate = Completer<void>();
    _queue = gate.future;
    return prev.then((_) async {
      try {
        return await task();
      } finally {
        await Future.delayed(_minRequestInterval);
        gate.complete();
      }
    });
  }

  static Future<BrowserResponse> _fetch(
    String url, {
    String method = 'GET',
    Map<String, String>? headers,
    List<int>? body,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    await _ensureReady();
    final controller = _webview?.webViewController;
    if (controller == null) {
      throw StateError('BrowserClient WebView not ready');
    }

    final id = ++_reqSeq;
    final h = <String, String>{
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      ...?headers,
    };
    // User-Agent / Referer 是浏览器的禁止改写请求头，XHR setRequestHeader 会被
    // 静默拒绝（日志报 Refused to set unsafe header），直接剔除避免噪音。
    // 实际 UA 是 WebView 内核自身的（TLS 指纹一致的正是它）；Worker 中继则由
    // worker 在服务端统一覆盖 UA。
    h.remove('User-Agent');
    h.remove('Referer');

    final bodyB64 = body == null ? null : base64Encode(body);
    final completer = Completer<dynamic>();
    _pending[id] = completer;

    final payload = jsonEncode({
      'id': id,
      'url': url,
      'method': method,
      'headers': h,
      'bodyB64': bodyB64,
    });

    const js = r'''
(function(){
  var payload = JSON.parse(payloadStr);
  function done(obj){
    try { window.flutter_inappwebview.callHandler('browserClientCb', obj); }
    catch(e){ console.log('browserClientCb fail ' + e); }
  }
  console.log('BrowserClient js run loc=' + location.href + ' url=' + payload.url);
  // wenku8 会把 https 跳到 http；必须用当前页同源请求，否则 CORS 拦截
  var target = payload.url;
  try {
    var u = new URL(target, location.href);
    if (u.origin !== location.origin) {
      u.protocol = location.protocol;
      u.host = location.host;
    }
    target = u.toString();
  } catch (e) {
    console.log('url rewrite fail ' + e);
  }
  console.log('BrowserClient target=' + target);
  var body = null;
  if (payload.bodyB64 && payload.bodyB64.length) {
    var bin = atob(payload.bodyB64);
    var bytes = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    body = bytes;
  }
  try {
    var xhr = new XMLHttpRequest();
    xhr.open(payload.method || 'GET', target, true);
    xhr.responseType = 'arraybuffer';
    xhr.withCredentials = true;
    var hs = payload.headers || {};
    for (var k in hs) {
      try { xhr.setRequestHeader(k, hs[k]); } catch(e) { console.log('setHeader ' + k + ' fail ' + e); }
    }
    xhr.onload = function(){
      try {
        var bytes = new Uint8Array(xhr.response || new ArrayBuffer(0));
        var bin = '';
        var CHUNK = 0x8000;
        for (var i = 0; i < bytes.length; i += CHUNK) {
          bin += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
        }
        done({ id: payload.id, ok: xhr.status >= 200 && xhr.status < 300, status: xhr.status, url: target,
               loc: location.href, cfMitigated: xhr.getResponseHeader('cf-mitigated') || '', bodyB64: btoa(bin) });
      } catch(e) {
        done({ id: payload.id, ok: false, status: 0, url: target, loc: location.href, error: 'encode:' + e, bodyB64: '' });
      }
    };
    xhr.onerror = function(){
      done({ id: payload.id, ok: false, status: 0, url: target, loc: location.href, title: document.title,
             error: 'xhr.onerror status=0', bodyB64: '' });
    };
    xhr.ontimeout = function(){
      done({ id: payload.id, ok: false, status: 0, url: target, loc: location.href, error: 'xhr.timeout', bodyB64: '' });
    };
    xhr.timeout = 20000;
    if (body) xhr.send(body); else xhr.send();
  } catch(e) {
    done({ id: payload.id, ok: false, status: 0, url: target, loc: location.href, error: 'xhr.ex:' + e, bodyB64: '' });
  }
  return 'started';
})()
''';

    try {
      await controller.evaluateJavascript(source: js.replaceFirst('payloadStr', jsonEncode(payload)));
    } catch (e) {
      _pending.remove(id);
      Log.e('BrowserClient: evaluateJavascript failed: $e');
      rethrow;
    }

    final dynamic json;
    try {
      json = await completer.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(id);
      throw StateError('BrowserClient fetch timeout: $url');
    }
    _pending.remove(id);

    if (json is! Map) {
      throw StateError('BrowserClient: bad callback payload: $json');
    }
    final m = Map<String, dynamic>.from(json);
    final status = (m['status'] as num?)?.toInt() ?? 0;
    final finalUrl = (m['url'] as String?) ?? url;
    final err = m['error'] as String?;
    final pageLoc = (m['loc'] as String?) ?? '';
    final cfMitigated = (m['cfMitigated'] as String?) ?? '';
    final b64 = m['bodyB64'] as String? ?? '';
    final bytes = b64.isEmpty ? Uint8List(0) : base64Decode(b64);

    if (err != null && err.isNotEmpty && status == 0) {
      // 带上 WebView 页面实际位置，便于区分"空页面请求"（about:blank/login 跳转）
      // 与"网络被重置"（CF 封禁时 https 握手被掐断）
      throw StateError('BrowserClient fetch failed: $err (page=$pageLoc)');
    }

    return BrowserResponse(
      statusCode: status,
      url: finalUrl,
      body: bytes,
      cfMitigated: cfMitigated,
    );
  }
}

class BrowserResponse {
  BrowserResponse({
    required this.statusCode,
    required this.url,
    required this.body,
    this.cfMitigated = '',
  });

  final int statusCode;
  final String url;
  final Uint8List body;

  /// CF 的 `cf-mitigated: challenge` 响应头（存在时），比嗅探 HTML 更可靠
  final String cfMitigated;

  bool get ok => statusCode >= 200 && statusCode < 300;

  bool get looksLikeLoginWall {
    if (statusCode == 403 || statusCode == 503) return true;
    if (cfMitigated.toLowerCase().contains('challenge')) return true;
    final head = body.isEmpty ? '' : String.fromCharCodes(body.take(2000));
    return head.contains('cf-mitigated') ||
        head.contains('Just a moment') ||
        head.contains('Checking your browser') ||
        head.contains('challenge-platform');
  }

  bool get looksLikeSessionExpired {
    final html = _asLatin1ish();
    if (html.isEmpty) return false;
    final hasLoginForm = html.contains('用户名或邮箱') || html.contains('login.php?do=login');
    const hasSessionMarkers = ['readbookcase', '退出登录', 'userdetail.php'];
    return hasLoginForm && !hasSessionMarkers.any(html.contains);
  }

  String _asLatin1ish() {
    if (body.isEmpty) return '';
    try {
      return utf8.decode(body, allowMalformed: true);
    } catch (_) {
      return String.fromCharCodes(body);
    }
  }
}
