// Cloudflare Worker — wenku8 反向代理中继
// 部署：Cloudflare Dashboard → Workers & Pages → Create → 粘贴此代码 → Deploy
// 自定义域名：Worker → Settings → Triggers → Custom Domains 绑定子域

const UPSTREAM = "www.wenku8.net";

export default {
  async fetch(request) {
    const url = new URL(request.url);
    url.protocol = "https:";
    url.host = UPSTREAM;

    const headers = new Headers(request.headers);
    headers.set("Host", UPSTREAM);
    headers.set("Referer", `https://${UPSTREAM}/`);
    headers.set("User-Agent",
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36");
    headers.set("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8");
    headers.set("Accept-Language", "zh-CN,zh;q=0.9");
    headers.delete("cf-connecting-ip");
    headers.delete("x-forwarded-for");
    headers.delete("x-real-ip");
    headers.delete("cf-ipcountry");
    headers.delete("cf-ray");
    headers.delete("cf-visitor");

    const req = new Request(url.toString(), {
      method: request.method,
      headers: headers,
      body: ["GET", "HEAD"].includes(request.method) ? null : request.body,
      redirect: "manual",  // 不跟随重定向，让 Set-Cookie 透传到客户端
    });

    let resp = await fetch(req);

    // 如果是重定向响应，改写 Location 到代理域名 + 剥离 Cookie 的 Domain 限制
    if ([301, 302, 303, 307, 308].includes(resp.status)) {
      const location = resp.headers.get("Location");
      const setCookies = resp.headers.getSetCookie ? resp.headers.getSetCookie() : [];

      const newResp = new Response(resp.body, resp);

      // 改写 Location：把 wenku8.net → 代理域名
      if (location) {
        try {
          const locUrl = new URL(location);
          if (locUrl.host === UPSTREAM) {
            locUrl.host = new URL(request.url).host;
            newResp.headers.set("Location", locUrl.toString());
          }
        } catch (e) { /* invalid URL, keep as-is */ }
      }

      // 剥离 Set-Cookie 的 Domain 属性，让 cookie 绑定到代理域名
      for (let raw of setCookies) {
        raw = raw.replace(/;\s*Domain=[^;]+/gi, "");
        raw = raw.replace(/;\s*SameSite=[^;]+/gi, "");
        newResp.headers.append("Set-Cookie", raw);
      }

      return newResp;
    }

    // 正常响应：透传
    resp = new Response(resp.body, resp);
    resp.headers.set("Access-Control-Allow-Origin", "*");
    resp.headers.set("Access-Control-Allow-Methods", "GET, POST, HEAD, OPTIONS");
    resp.headers.set("Access-Control-Allow-Headers", "*");
    return resp;
  }
};