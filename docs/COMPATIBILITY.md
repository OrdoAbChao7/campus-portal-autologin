# 兼容性与迁移评估

结论先给：**同一类 srun/深澜 v5 门户（`/api/account/*`）迁移成本最低，换门户地址和
nasId 基本可用；其他门户类型需要写适配器；PC 部署可行但有前提。**

## 1. 结论矩阵

| 场景 | 可行性 | 说明 |
|---|---|---|
| 同校另一有线口（同门户、同 BRAS 类型） | **高** | 改 `nasId`（看 BRAS 重定向 URL）即可 |
| 其他学校的 srun/深澜 v5（BingoCloud 前端） | **中高** | 接口可能同名同参；需核对 csrf/cookie、字段、验证码策略 |
| 老 srun（`/cgi-bin/srun_portal`、`srun_portal_pc`） | **低** | 参数、校验和（MD5/SHA1）、challenge 不同，需要适配器 |
| Dr.COM（城市热点） | **低** | `/drcom/login` 等接口，字段完全不同，需要新适配器 |
| 锐捷 ePortal | **低** | `/eportal/portal/login` 等，需要新适配器 |
| H3C / 802.1X / 客户端认证 | **不适用** | 不是网页门户，本方案不涉及 |
| 每次登录都必须验证码 | **不适用** | 设计上遇到 `code 2` 即停止，不做识别 |
| 纯 HTTPS 门户 | **中** | 当前 `nc` 只支持 HTTP；需 curl 变体（或在网关装 curl/改用其他语言） |
| 纯 IPv6 网络 | **低** | 需要 IPv6 版请求与状态判断 |
| 门户按 IP+MAC 强绑定 | **中** | 网关路由器上运行最稳（能拿到 WAN MAC）；PC 在 NAT 后拿不到 WAN MAC |

## 2. 迁移到“别人的电脑”

### 2.1 三种部署位置

1. **网关路由器（推荐，已验证）**
   - 脚本能看到 WAN IP/MAC，能选做 WAN 重连，最贴近 NAS 的记录。
   - 适用 OpenWrt/Linux 路由器；需要 root，cron。

2. **同一 LAN 内的 PC（Windows/Linux，beta）**
   - 门户按**来源 IP** 认证，PC 的请求经 NAT 后来源是路由器公网 IP，因此 PC 可以
     维持**路由器**的会话；状态检查已在本机验证（`session: online`）。
   - 但 PC 不知道 WAN 的 MAC：Windows 版登录体里不带 `userMac`/`userIpv4`，由服务端
     按来源 IP 处理。若某校强制 MAC 与会话一致，PC 版登录会失败——此时应改用网关部署。
   - 优点：不碰路由器、不需要 root；缺点：PC 关机就没人保活。

3. **直接认证的设备（校园 Wi-Fi/有线直连）**
   - 认证的是设备自身 IP，逻辑同样适用；脚本在 PC 上即可。

### 2.2 PC 版的前置条件

- 能直接访问门户（系统代理需放行门户 IP；本项目在 PC 的分发器里加了
  `172.30.0.0/12`、校园 WAN 网段和学校域名直连）。
- 能拿到 nasId（未认证时浏览器会被重定向到带 `nasId=` 的 URL；或问网管/看抓包）。
- Windows 用 DPAPI 存密码；Linux 用 600 文件。

## 3. 迁移到别的校园：按门户类型

### 3.1 srun/深澜 v5（本实现，`/api/account/login`）

迁移步骤：

1. 关掉代理，打开任意 HTTP 站点，记录被重定向到的门户 URL：
   `…/tpl/<school>/login.html?acip=…&nasId=…&ip=…`。
2. 浏览器 DevTools → Network，确认登录请求是 `POST /api/account/login`，
   字段含 `username/password/nasId/userIpv4/userMac`。
3. 配置 `PORTAL_HOST`（门户 IP）、`NAS_ID`（重定向 URL 里的值）。
4. 先跑 `status`（只读）；在线/离线判断正确后再启用 cron。

需要留意的差异：

- CSRF：有的版本不需要 `X-CSRF-Token`，有的用别的头；本实现按 BingoCloud 版本。
- Cookie 名：本实现抓取 `yudear`；其他部署可能是 `PHPSESSID` 等，需要调整。
- 验证码：`err_count_captcha` 阈值不同；有的学校首次登录就要验证码 → 不适用。
- 字段名：`userIpv4`/`userMac` 可能叫 `user_ip`/`user_mac`。

### 3.2 老 srun（`/cgi-bin/srun_portal` 或 `srun_portal_pc`）

需要适配器，不是改配置能解决：

- 参数：`action=login&username=…&password={MD5}…&ac_id=…&user_ip=…&user_mac=…&chksum=…`。
- 通常需要 `chksum`（对固定串拼接后做 MD5/SHA1），有的还要先取 challenge。
- 建议：先用浏览器抓一次成功登录的完整请求，再按该请求实现（凭据仍只存本机）。

### 3.3 Dr.COM / 锐捷 ePortal

- Dr.COM：`/drcom/login`、`0.htm`、`wlan_user_ip` 等，常带 `callback` 和加密字段。
- 锐捷：`/eportal/portal/login`、`user_account` 等，常见 `user_account=,<user>` 格式。
- 共同点：都需要按抓包实现适配器；本代码的**状态机、退避、验证码策略、凭据安全**
  可以直接复用，只需替换“查状态”和“发登录”两个函数。

### 3.4 不适合的情况

- 每次登录都要图形验证码/短信/双因素；
- 802.1X 或专有客户端；
- 学校明确禁止自动登录/脚本认证；
- 账号有单设备限制且你还需要在手机上使用同一账号（自动登录可能互相踢）。

## 4. 验证清单（迁移后必做）

1. `status` 在在线与离线两种状态下结果正确（离线可用“换一个未认证网口/临时注销”验证，
   但会断网，需授权）。
2. 受控注销一次，确认脚本能在下一个周期内恢复；记录耗时。
3. 故意用错误 nasId 跑一次 `test-login`（离线时），确认得到 `code 1` 并进入退避，
   而不是死循环。
4. 观察 24 小时日志：不应出现频繁登录（正常应只在失效时出现 1 次成功）。
5. 确认凭据文件权限、日志无敏感信息。

## 5. 风险与合规

- 自动登录可能违反校园网使用条款；部署前确认学校规定。
- 账号锁定：脚本有退避，但错误密码仍会累计；密码变更后请立即更新凭据。
- 单设备限制：自动登录与手机登录可能互相顶掉，属校园策略，脚本无法规避。
- 本实现不包含任何绕过验证码/反爬的能力，也不应被这样使用。
