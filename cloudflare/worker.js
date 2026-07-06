// Cloudflare Worker — wenku8 反向代理中继
// 部署：Cloudflare Dashboard → Workers & Pages → 粘贴此代码 → Deploy

const UPSTREAM = "www.wenku8.net";

export default {
  async fetch(request) {
    const proxyHost = new URL(request.url).host;
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
      redirect: "manual",
    });

    let resp = await fetch(req);

    // 重定向响应：改写 Location + 透传 Set-Cookie
    if ([301, 302, 303, 307, 308].includes(resp.status)) {
      const newResp = new Response(resp.body, resp);

      // 改写 Location
      const location = resp.headers.get("Location");
      if (location) {
        try {
          let newLoc = location;
          // 替换所有出现的 wenku8 上游域名
          newLoc = newLoc.replace(new RegExp("//" + UPSTREAM, "gi"), "//" + proxyHost);
          newLoc = newLoc.replace(new RegExp(UPSTREAM, "g"), proxyHost);
          newResp.headers.set("Location", newLoc);
        } catch (e) {
          newResp.headers.set("Location", location);
        }
      }

      // 透传 Set-Cookie，剥离 Domain 限制
      const setCookies = resp.headers.getSetCookie ? resp.headers.getSetCookie() : [];
      for (let raw of setCookies) {
        raw = raw.replace(/;\s*Domain=[^;]+/gi, "");
        raw = raw.replace(/;\s*SameSite=[^;]+/gi, "");
        newResp.headers.append("Set-Cookie", raw);
      }

      return newResp;
    }

    // 正常响应
    resp = new Response(resp.body, resp);
    resp.headers.set("Access-Control-Allow-Origin", "*");
    resp.headers.set("Access-Control-Allow-Methods", "GET, POST, HEAD, OPTIONS");
    resp.headers.set("Access-Control-Allow-Headers", "*");
    return resp;
  }
};