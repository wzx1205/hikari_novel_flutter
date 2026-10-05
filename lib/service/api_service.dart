import 'dart:convert';
import 'dart:ui';

import 'package:enough_convert/enough_convert.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:hikari_novel_flutter/common/constants.dart';
import 'package:hikari_novel_flutter/common/extension.dart';
import 'package:hikari_novel_flutter/models/common/charset_type.dart';
import 'package:hikari_novel_flutter/models/common/language.dart';
import 'package:hikari_novel_flutter/models/common/wenku8_node.dart';
import 'package:hikari_novel_flutter/models/custom_exception.dart';
import 'package:hikari_novel_flutter/models/resource.dart';
import 'package:hikari_novel_flutter/network/browser_client.dart';

import '../common/log.dart';
import '../main.dart' show webViewEnvironment;
import 'local_storage_service.dart';

class ApiService extends GetxService {
  static ApiService get instance => Get.find<ApiService>();

  Wenku8Node get wenku8Node => LocalStorageService.instance.getWenku8Node();

  final _ApiClient _client = _ApiClient();

  Future<void> initCookie() => _client.initCookie();

  Future<void> deleteCookie() => _client.deleteCookie();

  Language get _language => LocalStorageService.instance.getLanguage();

  CharsetType get charsetType {
    if (_language == Language.followSystem) {
      if (Get.deviceLocale == Locale("zh", "CN")) {
        return CharsetType.gbk;
      } else if (Get.deviceLocale == Locale("zh", "TW")) {
        return CharsetType.big5Hkscs;
      } else {
        return CharsetType.gbk;
      }
    }
    return switch (_language) {
      Language.simplifiedChinese => CharsetType.gbk,
      Language.traditionalChinese => CharsetType.big5Hkscs,
      _ => CharsetType.gbk,
    };
  }

  /// 根据排名获取小说列表
  /// - [ranking] 排行榜种类
  /// - [index] 第几页
  Future<Resource> getNovelByRanking({required String ranking, required int index}) {
    final String url = "${wenku8Node.node}/modules/article/toplist.php?sort=$ranking&page=$index";
    return _client.get(url, charsetType: charsetType);
  }

  /// 根据分类获取小说列表
  /// - [category] 小说的分类，即tag
  /// - [sort] 按什么排序
  /// - [index] 第几页
  Future<Resource> getNovelByCategory({required String category, required String sort, required int index}) {
    switch (charsetType) {
      case CharsetType.gbk:
        {
          category = GbkCodec().encode(category).map((b) => '%${b.toRadixString(16).padLeft(2, '0').toUpperCase()}').join().trim();
        }
      case CharsetType.big5Hkscs:
        {
          category = Big5Codec().encode(category).map((b) => '%${b.toRadixString(16).padLeft(2, '0').toUpperCase()}').join().trim();
        }
    }
    String url = "${wenku8Node.node}/modules/article/tags.php?t=$category&v=$sort&page=$index";
    return _client.get(url, charsetType: charsetType);
  }

  /// 获取小说信息
  /// - [aid] 小说的id
  Future<Resource> getNovelDetail({required String aid}) {
    final String url = "${wenku8Node.node}/modules/article/articleinfo.php?id=$aid";
    return _client.get(url, charsetType: charsetType);
  }

  /// 获取小说的章节目录
  /// - [aid] 小说的id
  Future<Resource> getCatalogue({required String aid}) {
    final String url = "${wenku8Node.node}/modules/article/reader.php?aid=$aid";
    return _client.get(url, charsetType: charsetType);
  }

  /// 加入书库
  /// - [aid] 小说的id
  Future<Resource> addNovel({required String aid}) {
    final String url = "${wenku8Node.node}/modules/article/addbookcase.php?bid=$aid";
    return _client.get(url, charsetType: charsetType);
  }

  /// 移出书库
  /// - [delid] 该书在书架中的id，即bid
  Future<Resource> removeNovel({required String delid}) {
    final String url = "${wenku8Node.node}/modules/article/bookcase.php?delid=$delid";
    return _client.get(url, charsetType: charsetType);
  }

  /// 从列表移出书库
  /// - [list] 要删除的书籍列表
  /// - [classId] 要将这些书从哪个书架中删除
  Future<Resource> removeNovelFromList({required List<String> list, required int classId}) {
    final String url = "${wenku8Node.node}/modules/article/bookcase.php";
    final Map<String, dynamic> params = {"checkid[]": list, "classlist": classId, "checkall": "checkall", "newclassid": -1, "classid": classId};
    return _client.postForm(url, data: params, charsetType: charsetType);
  }

  /// 移动到其它书架
  /// - [list] 要移动的书籍列表
  /// - [classId] 要将这些书从哪个书架中移出
  /// - [newClassId] 要将这些书移动到那个书架中
  Future<Resource> moveNovelToOther({required List<String> list, required int classId, required int newClassId}) {
    final String url = "${wenku8Node.node}/modules/article/bookcase.php";
    final Map<String, dynamic> params = {"checkid[]": list, "classlist": classId, "checkall": "checkall", "newclassid": newClassId, "classid": classId};
    return _client.postForm(url, data: params, charsetType: charsetType);
  }

  /// 获取书架
  ///
  /// 书架走 WebView 真导航抓取（navigateFetch）：文库 CF 对 bookcase.php 的
  /// XHR 式请求一律 403（同 IP 实测浏览器导航可达），且 Worker 中继转发导航
  /// 也会被按数据中心来源拦掉，故固定直连 wenku8.net。
  /// - [classId] 要获取的书架编号
  Future<Resource> getBookshelf({required int classId}) {
    final String url = "https://www.wenku8.net/modules/article/bookcase.php?classid=$classId";
    return _client.getViaNavigation(url);
  }

  /// 获取其它用户收藏的书籍
  /// - [uid] 该用户的id
  Future<Resource> getBookshelfFromUser({required String uid}) {
    final String url = "${wenku8Node.node}/userpage.php?uid=$uid";
    return _client.get(url, charsetType: charsetType);
  }

  /// 获取评论区
  /// - [aid] 该评论区所属的书籍的id
  /// - [index] 第几页
  Future<Resource> getComment({required String aid, required int index}) {
    final String url = "${wenku8Node.node}/modules/article/reviews.php?aid=$aid&page=$index";
    return _client.get(url, charsetType: charsetType);
  }

  /// 获取回复
  /// - [rid] 该回复的id
  /// - [index] 第几页
  Future<Resource> getReply({required String rid, required int index}) {
    final String url = "${wenku8Node.node}/modules/article/reviewshow.php?rid=$rid&page=$index";
    return _client.get(url, charsetType: charsetType);
  }

  /// 获取推荐页
  Future<Resource> getRecommend() {
    final String url = "${wenku8Node.node}/index.php";
    return _client.get(url, charsetType: charsetType);
  }

  /// 为小说投票
  /// - [aid] 被投票的小说的id
  Future<Resource> novelVote({required String aid}) {
    final String url = "${wenku8Node.node}/modules/article/uservote.php?id=$aid";
    return _client.get(url, charsetType: charsetType);
  }

  /// 根据标题搜索小说
  /// - [title] 标题关键字
  /// - [index] 第几页
  Future<Resource> searchNovelByTitle({required String title, required int index}) {
    switch (charsetType) {
      //url编码
      case CharsetType.gbk:
        title = GbkEncoder().convert(title).map((b) => '%${b.toRadixString(16).padLeft(2, '0').toUpperCase()}').join();
      case CharsetType.big5Hkscs:
        title = Big5Encoder().convert(title).map((b) => '%${b.toRadixString(16).padLeft(2, '0').toUpperCase()}').join();
    }
    final String url = "${wenku8Node.node}/modules/article/search.php?searchtype=articlename&searchkey=$title&page=$index";
    return _client.get(url, charsetType: charsetType);
  }

  /// 根据作者搜索小说
  /// - [author] 作者关键字
  /// - [index] 第几页
  Future<Resource> searchNovelByAuthor({required String author, required int index}) {
    switch (charsetType) {
      //url编码
      case CharsetType.gbk:
        author = GbkEncoder().convert(author).map((b) => '%${b.toRadixString(16).padLeft(2, '0').toUpperCase()}').join();
      case CharsetType.big5Hkscs:
        author = Big5Encoder().convert(author).map((b) => '%${b.toRadixString(16).padLeft(2, '0').toUpperCase()}').join();
    }
    final String url = "${wenku8Node.node}/modules/article/search.php?searchtype=author&searchkey=$author&page=$index";
    return _client.get(url, charsetType: charsetType);
  }

  /// 获取用户信息
  Future<Resource> getUserInfo() {
    final String url = "${wenku8Node.node}/userdetail.php";
    return _client.get(url, charsetType: charsetType);
  }

  /// 获取已完结小说的列表
  /// - [index] 第几页
  Future<Resource> getCompletionNovel({required int index}) {
    final String url = "${wenku8Node.node}/modules/article/articlelist.php?fullflag=1&page=$index";
    return _client.get(url, charsetType: charsetType);
  }

  /// 发表书评
  /// - [aid] 书号
  /// - [title] 书评的标题
  /// - [content] 书评的内容
  Future<Resource> sendComment({required String aid, required String title, required String content}) {
    final String url = "${wenku8Node.node}/modules/article/reviews.php?aid=$aid";

    String submit;
    switch (charsetType) {
      case CharsetType.gbk:
        submit = GbkEncoder().convert("发表书评").map((b) => '%${b.toRadixString(16).padLeft(2, '0').toUpperCase()}').join();
        title = title.gbkUrlEncodingIfNotAscii();
        content = content.gbkUrlEncodingIfNotAscii();
      case CharsetType.big5Hkscs:
        submit = Big5Encoder().convert("發表書評").map((b) => '%${b.toRadixString(16).padLeft(2, '0').toUpperCase()}').join();
        title = title.big5UrlEncodingIfNotAscii();
        content = content.big5UrlEncodingIfNotAscii();
    }
    //加上url编码的空格，即"+"
    submit = "+$submit+";

    final String params = "ptitle=$title&pcontent=$content&Submit=$submit";
    return _client.postForm(url, data: params, charsetType: charsetType);
  }

  /// 发表回复
  /// - [aid] 书号
  /// - [rid] 要回复的书评id
  /// - [content] 回复的内容
  Future<Resource> sendReply({required String aid, required String rid, required String content}) {
    final String url = "${wenku8Node.node}/modules/article/reviewshow.php?rid=$rid&aid=$aid";

    String submit;
    switch (charsetType) {
      case CharsetType.gbk:
        submit = GbkEncoder().convert("发表书评").map((b) => '%${b.toRadixString(16).padLeft(2, '0').toUpperCase()}').join();
        content = content.gbkUrlEncodingIfNotAscii();
      case CharsetType.big5Hkscs:
        submit = Big5Encoder().convert("發表書評").map((b) => '%${b.toRadixString(16).padLeft(2, '0').toUpperCase()}').join();
        content = content.big5UrlEncodingIfNotAscii();
    }
    //加上url编码的空格，即"+"
    submit = "+$submit+";

    final String params = "pcontent=$content&Submit=$submit";

    return _client.postForm(url, data: params, charsetType: charsetType);
  }

  /// 获取小说章节内容
  /// - [aid] 小说id
  /// - [cid] 章节id
  Future<Resource> getNovelContent({required String aid, required String cid}) {
    final String url = "${wenku8Node.node}/modules/article/reader.php?aid=$aid&cid=$cid";
    return _client.get(url, charsetType: charsetType);
  }

  /// 登录（对照 iOS scripting：POST login.php?do=login，而不是 WebView 表单的 do=submit）
  ///
  /// WebView 直接 submit 到 `login.php?do=submit` 会撞 CF 硬 403；
  /// scripting 用同 TLS 栈的 XHR 打 `do=login` 可以过。
  /// [useCookieSeconds] 保存登录时长（秒），默认 1 年 = 31536000。
  Future<LoginResult> login(String username, String password, {int useCookieSeconds = 31536000}) async {
    try {
      // 先等 CF 盾过，否则 XHR 会直接打到挑战页
      await BrowserClient.ensureChallengeCleared();
      final userEnc = _gbkPercent(username);
      final passEnc = _gbkPercent(password);
      final submitEnc = _gbkPercent('登 录');
      // 与 scripting api.ts login body 完全一致
      final body = 'username=$userEnc&password=$passEnc&usecookie=$useCookieSeconds&action=login&submit=$submitEnc';

      LoginResult? result;
      for (var attempt = 0; attempt < 3; attempt++) {
        final res = await BrowserClient.fetch(
          '${wenku8Node.node}/login.php?do=login',
          method: 'POST',
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
            'Referer': '${wenku8Node.node}/login.php',
          },
          body: utf8.encode(body),
        );

        final html = GbkDecoder().convert(res.body);
        Log.d('[login] attempt=$attempt status=${res.statusCode} url=${res.url} bytes=${res.body.length}');

        // 命中 CF 挑战页：等盾解开再试
        final challenged = res.looksLikeLoginWall ||
            html.contains('Just a moment') ||
            html.contains('challenge-platform') ||
            html.contains('Checking your browser') ||
            html.contains('请稍候');
        if (challenged && attempt < 2) {
          Log.w('[login] hit CF challenge, wait and retry');
          await BrowserClient.ensureChallengeCleared(timeout: const Duration(seconds: 12));
          continue;
        }

        if (res.statusCode == 403) {
          result = LoginResult.fail(cloudflare403ExceptionMessage);
          break;
        }
        // scripting 判定：登录成功页文案，或跳到 do=submit
        if (html.contains('登录成功') || res.url.contains('do=submit')) {
          result = LoginResult.ok(html);
          break;
        }
        if (html.contains('密码错误') || html.contains('密码不正确')) {
          result = LoginResult.fail('密码错误');
          break;
        }
        if (html.contains('用户不存在')) {
          result = LoginResult.fail('用户不存在');
          break;
        }
        if (challenged) {
          result = LoginResult.fail('CF 人机验证未通过，请稍后重试或切换节点');
          break;
        }
        result = LoginResult.fail('登录失败，请检查账号密码');
        break;
      }
      return result ?? LoginResult.fail('登录失败');
    } catch (e) {
      Log.e('[login] error $e');
      return LoginResult.fail(e.toString());
    }
  }

  String _gbkPercent(String s) {
    final bytes = GbkEncoder().convert(s);
    return bytes.map((b) => '%${b.toRadixString(16).padLeft(2, '0').toUpperCase()}').join();
  }

  /// 获取Github上面的最新版本
  Future<Resource> fetchLatestRelease() {
    return _client.getCommonData(kLatestUrl);
  }
}

class LoginResult {
  LoginResult.ok(this.html) : success = true, message = '登录成功';
  LoginResult.fail(this.message) : success = false, html = '';

  final bool success;
  final String html;
  final String message;
}

class _ApiClient {
  /// WebView 共享 cookie jar：登录页拿到的 cookie 对 fetch 同样生效
  Future<void> initCookie() async {
    final localCookie = LocalStorageService.instance.getCookie();
    if (localCookie == null) return;

    final pairs = localCookie
        .split(';')
        .map((e) => e.trim())
        .where((e) => e.contains('='))
        .map((e) {
          final eq = e.indexOf('=');
          return MapEntry(e.substring(0, eq), e.substring(eq + 1));
        })
        .toList();

    final cm = CookieManager.instance(webViewEnvironment: webViewEnvironment);
    final domains = [Wenku8Node.wwwWenku8Cc.node, Wenku8Node.wwwWenku8Net.node, Wenku8Node.proxyWorker.node];
    for (final base in domains) {
      for (final kv in pairs) {
        try {
          await cm.setCookie(
            url: WebUri(base),
            name: kv.key,
            value: kv.value,
            domain: Uri.parse(base).host,
            isSecure: true,
          );
        } catch (e) {
          Log.w('initCookie setCookie failed: $e');
        }
      }
    }
  }

  Future<void> deleteCookie() async {
    try {
      await CookieManager.instance(webViewEnvironment: webViewEnvironment).deleteAllCookies();
    } catch (_) {}
  }

  Future<Resource> getCommonData(String url) async {
    try {
      final res = await BrowserClient.fetch(url);
      if (res.looksLikeLoginWall && res.statusCode == 403) {
        return Error(cloudflare403ExceptionMessage);
      }
      return Success(utf8.decode(res.body, allowMalformed: true));
    } catch (e) {
      return Error(e.toString());
    }
  }

  Future<Resource> get(String url, {required CharsetType charsetType}) async {
    try {
      if (!url.contains("?")) url += "?";
      switch (charsetType) {
        case CharsetType.gbk:
          url += "&charset=gbk";
        case CharsetType.big5Hkscs:
          url += "&charset=big5";
      }

      Log.d("$url ${charsetType.name}");
      final res = await BrowserClient.fetch(url);
      Log.d('[res] status=${res.statusCode} bytes=${res.body.length} url=${res.url} '
          'loginWall=${res.looksLikeLoginWall} sessionExpired=${res.looksLikeSessionExpired}');
      final html = _decode(res, charsetType);

      if (res.statusCode == 403) return Error(cloudflare403ExceptionMessage);
      if (res.looksLikeLoginWall && res.looksLikeSessionExpired) {
        return Error(sessionExpiredMessage);
      }

      return Success(html);
    } catch (e) {
      Log.e(e.toString());
      return Error(e.toString());
    }
  }

  /// 会员页（书架等）：经 WebView 真导航抓取。
  /// 返回的 HTML 已由浏览器解码为 UTF-8 文本，无需再做 GBK 转换。
  Future<Resource> getViaNavigation(String url) async {
    try {
      final res = await BrowserClient.navigateFetch(url);
      Log.d('[nav-res] bytes=${res.body.length} url=${res.url} '
          'loginWall=${res.looksLikeLoginWall} sessionExpired=${res.looksLikeSessionExpired}');
      final html = utf8.decode(res.body, allowMalformed: true);
      if (res.looksLikeLoginWall) return Error(cloudflare403ExceptionMessage);
      if (res.looksLikeSessionExpired) return Error(sessionExpiredMessage);
      return Success(html);
    } catch (e) {
      Log.e(e.toString());
      return Error(e.toString());
    }
  }

  Future<Resource> postForm(String url, {required Object? data, required CharsetType charsetType}) async {
    try {
      // data 可能是已编码的 String 或 Map；统一成 form-urlencoded 字节
      final String form;
      if (data is String) {
        form = data;
      } else if (data is Map) {
        form = data.entries
            .map((e) => '${Uri.encodeComponent(e.key.toString())}=${Uri.encodeComponent(e.value.toString())}')
            .join('&');
      } else {
        form = '';
      }

      final res = await BrowserClient.fetch(
        url,
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Referer': url,
        },
        body: utf8.encode(form),
      );
      final html = _decode(res, charsetType);

      if (res.statusCode == 403) return Error(cloudflare403ExceptionMessage);
      return Success(html);
    } catch (e) {
      Log.e(e.toString());
      return Error(e.toString());
    }
  }

  String _decode(BrowserResponse res, CharsetType charsetType) {
    final raw = res.body;
    switch (charsetType) {
      case CharsetType.gbk:
        return GbkDecoder().convert(raw);
      case CharsetType.big5Hkscs:
        return Big5Decoder().convert(raw);
    }
  }
}
