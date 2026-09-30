import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../common/log.dart';
import '../main.dart' show webViewEnvironment;

/// WebView fetch 传输层。
///
/// Cloudflare 的 cf_clearance / 挑战与 TLS 指纹绑定：Dio(dart:io) 的指纹过不了盾，
/// WebView（系统浏览器内核）可以。所有 wenku8 请求统一走 WebView 内的 fetch，
/// 与登录页同一 TLS 栈，从而不再被 CF 拦。
class BrowserClient {
  BrowserClient._();

  static HeadlessInAppWebView? _webview;
  static Future<void>? _initFuture;
  static int _reqSeq = 0;

  static Future<void> _ensureReady() => _initFuture ??= _init();

  static Future<void> _init() async {
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
      initialUrlRequest: URLRequest(url: WebUri('https://www.wenku8.net/index.php')),
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
    await _waitForChallengeClear(timeout: const Duration(seconds: 20));
  }

  /// 轮询当前页是否已过 CF 盾。挑战页标题一般是 Just a moment / 请稍候 / Attention Required
  static Future<void> _waitForChallengeClear({Duration timeout = const Duration(seconds: 20)}) async {
    final deadline = DateTime.now().add(timeout);
    var reloaded = false;
    while (DateTime.now().isBefore(deadline)) {
      try {
        final title = await _webview?.webViewController?.getTitle();
        final t = title?.toLowerCase() ?? '';
        Log.d('BrowserClient: page title=$title');
        final challenged = t.contains('just a moment') ||
            t.contains('attention required') ||
            t.contains('checking your browser') ||
            t.contains('please wait') ||
            t.contains('请稍候') ||
            t.contains('请稍等') ||
            t.contains('验证');
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
          await _webview?.webViewController?.reload();
        } catch (_) {}
      }
      await Future.delayed(const Duration(milliseconds: 800));
    }
    Log.w('BrowserClient: challenge not cleared in time (continue anyway)');
  }

  /// 公开：确保 CF 盾已过（登录前调用）
  static Future<void> ensureChallengeCleared({Duration timeout = const Duration(seconds: 15)}) {
    return _waitForChallengeClear(timeout: timeout);
  }

  static final Map<dynamic, Completer<dynamic>> _pending = {};

  static Future<void> dispose() async {
    final wv = _webview;
    _webview = null;
    _initFuture = null;
    _pending.clear();
    try {
      await wv?.dispose();
    } catch (_) {}
  }

  static Future<BrowserResponse> fetch(
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
    // 与 iOS scripting 一致：iPhone Safari UA，CF 对这套指纹更友好
    const kIphoneUA =
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1';
    final h = <String, String>{
      'User-Agent': kIphoneUA,
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      ...?headers,
    };
    // User-Agent 允许调用方覆盖
    if (headers != null && headers.containsKey('User-Agent')) {
      h['User-Agent'] = headers['User-Agent']!;
    }

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
        done({ id: payload.id, ok: xhr.status >= 200 && xhr.status < 300, status: xhr.status, url: target, bodyB64: btoa(bin) });
      } catch(e) {
        done({ id: payload.id, ok: false, status: 0, url: target, error: 'encode:' + e, bodyB64: '' });
      }
    };
    xhr.onerror = function(){
      done({ id: payload.id, ok: false, status: 0, url: target, error: 'xhr.onerror status=' + xhr.status, bodyB64: '' });
    };
    xhr.ontimeout = function(){
      done({ id: payload.id, ok: false, status: 0, url: target, error: 'xhr.timeout', bodyB64: '' });
    };
    xhr.timeout = 20000;
    if (body) xhr.send(body); else xhr.send();
  } catch(e) {
    done({ id: payload.id, ok: false, status: 0, url: target, error: 'xhr.ex:' + e, bodyB64: '' });
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
    final b64 = m['bodyB64'] as String? ?? '';
    final bytes = b64.isEmpty ? Uint8List(0) : base64Decode(b64);

    if (err != null && err.isNotEmpty && status == 0) {
      throw StateError('BrowserClient fetch failed: $err');
    }

    return BrowserResponse(statusCode: status, url: finalUrl, body: bytes);
  }
}

class BrowserResponse {
  BrowserResponse({
    required this.statusCode,
    required this.url,
    required this.body,
  });

  final int statusCode;
  final String url;
  final Uint8List body;

  bool get ok => statusCode >= 200 && statusCode < 300;

  bool get looksLikeLoginWall {
    if (statusCode == 403 || statusCode == 503) return true;
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
