# 协议观察：srun/深澜 v5（BingoCloud 前端）

以下为对 WHUT 有线门户的只读观察与一次受控登录的结果，值已脱敏。接口和参数可能随
门户版本变化，部署前请用浏览器 DevTools 复核。

## 1. 识别特征

- `Server: BingoCloud`（深澜 srun 的常见前端）。
- 根路径 302 → `/api/r/default` → `/api/r/<nasId>` → `/tpl/<学校>/login.html?...`。
- 登录页 JS：`static/js/config.js`（`host_url='/api'`）、`csrf.js`（先取 CSRF token，
  之后所有 AJAX 带 `X-CSRF-Token`）。
- 登录表单字段：`username/password/switchip/nasId/userIpv4/userMac/captcha/captchaId`。

## 2. BRAS 重定向

未认证时，任意 HTTP（80 端口）请求被 BRAS 重定向到：

```
http://<portal>/tpl/<school>/login.html
    ?acip=<BRAS-IP>&acname=<BRAS-NAME>&ip=<WAN-IP>&nasId=<NAS-ID>
    &userip=<WAN-IP>&wlanacname=
```

- `nasId`：本端口接入服务器编号，登录必须匹配。
- `acip`/`acname`：BRAS 的地址与名称（会话 SessionId 也包含 acip）。
- `ip`/`userip`：客户端公网 IP（NAT 后为网关 WAN IP）。

## 3. 接口

### 3.1 会话状态

```
GET /api/account/status
```

无需 token，按**请求来源 IP** 返回该 IP 的会话：

```json
{"authCode":"","authMsg":"","code":0,"dialCode":"ok:dialup","dialMsg":"已拨号成功",
 "enableDial":true,"macOnlineCount":1,"msg":"在线",
 "online":{"AddTime":"2026-11-09T19:51:20+08:00","BytesIn4":"…","Name":"<name>",
           "SessionId":"<acip>-<school>-<id>","UserIpv4":"<wan-ip>","UserIpv6":"",
           "UserMac":"<wan-mac>","UserSourceType":"local","Username":"<account>"},
 "token":"<session-token>"}
```

- 在线判定：`code == 0` 且 `online.Username` 非空。
- 离线时返回非 0 code 或缺 `online` 对象（即使返回 302/HTML，也按离线处理）。

### 3.2 CSRF

```
GET /api/csrf-token
Set-Cookie: yudear=<signed-session>; Path=/; Max-Age=2592000
{"csrf_token":"<token>"}
```

`csrf_token` 与 `yudear` cookie 绑定，登录时必须同时带回。

### 3.3 门户配置

```
GET /api/config
{"code":0,"data":{"config":{"default_nas":"14","err_count_captcha":"10",
 "auth_methods":"account","enable_self_service":"1",
 "selfservice_url":"http://selfaaa.<school>"}}}
```

- `default_nas` 只是默认页，**不是**当前端口的 NAS id。
- `err_count_captcha`：连续错误多少次后要求验证码。

### 3.4 登录

```
POST /api/account/login
Content-Type: application/x-www-form-urlencoded
X-CSRF-Token: <token>
Cookie: yudear=<signed-session>

username=<account>&password=<password>&switchip=&nasId=<nas>
&userIpv4=<wan-ip>&userMac=<wan-mac>&captcha=&captchaId=
```

返回：

```json
{"code":0,"token":"<session-token>"}          // 成功
{"code":1,"msg":"您的设备IP不在线，请断开网络重新连接后再次登陆。"}  // 失败
{"code":2,"msg":"请输入验证码","captcha":{"picPath":"…","captchaId":"…"}} // 需验证码
```

`code 0` 不代表会话一定可用：在线重复登录时，门户会先返回成功再终止原会话。

### 3.5 登出（脚本不会调用）

```
GET /api/account/logout?token=<session-token>
```

## 4. 会话语义与坑

1. **会话绑定 IP + MAC**：NAS 侧按 WAN IP/MAC 记录；DHCP 换 IP 可能失效。
2. **重复登录会踢掉原会话**：在线状态下再发登录，门户先回 `code 0`，随后原会话被终止，
   下一次登录报“设备IP不在线”。
3. **“设备IP不在线”有三种成因**：
   - nasId 与端口不匹配（最常见）；
   - 在线状态下重复登录（先成功后掉线）；
   - NAS 的在线表尚未登记该 IP（需要链路重连或等待）。
4. **无感知/MAC 认证**：部分端口在链路重连后会自动按 MAC 恢复；此时不需要凭据登录。
   登录页 `/api/config` 的 `auth_methods=account` 只表示网页登录方式，不代表 NAS 不支持 MAC。
5. **验证码**：正常登录不需要；连续错误达到 `err_count_captcha` 后出现。

## 5. 解析注意事项

- JSON 的 `code` 字段出现在响应开头；用 `sed` 取第一个 `"code":<n>` 足够。
- HTTP 响应含头，解析 body 时不要假设单行；本实现用 grep/sed 在全文匹配。
- busybox `nc` 没有超时参数：保持 stdin 打开几秒、依赖 `Connection: close` 读取完整响应。
- 门户只支持 HTTP（当前实现）；HTTPS 门户需要 curl 变体。

## 6. 兼容性判断（快速）

打开门户登录页，DevTools → Network，找登录请求：

- 路径是 `/api/account/login`，字段如上是 → 本实现可直接用。
- 路径是 `/cgi-bin/srun_portal` 或 `srun_portal_pc` → 老 srun，需要适配器。
- 路径是 `/drcom/...` 或 `/eportal/...` → Dr.COM/锐捷，需要新适配器。
