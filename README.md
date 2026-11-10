# 校园网门户自动重登录（Campus Portal Auto-Login）

守住一条已经认证的校园网会话：掉线后自动用**你自己的账号**重新登录，最多等一个巡检周期。
不破解验证码、不绕过认证、不共享账号。

- 参考实现：OpenWrt 路由器（R3G，MT7621）+ WHUT 有线门户（srun/深澜 BingoCloud 前端），
  状态 **PASS**（受控注销后自动登录并验证在线）。
- Windows PC 版：**beta**（在线状态检查已验证；登录路径与路由器同协议，未在同校 PC 上重测）。
- 其他校园的兼容性：**取决于门户类型**，见 [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md)。

## 它解决什么问题

网页认证（captive portal）的网络，会话会因重启、DHCP 续租、学校策略（隔几天）而失效。
失效后要么手动打开门户登录，要么断网。这个脚本把「发现掉线 → 登录 → 验证」变成自动的，
并且**在线时什么都不做**。

## 它不做什么

- 不破解、不绕过验证码；门户要求验证码时停止并记日志，等人工登录。
- 不在会话在线时补登录（这会把原会话踢掉）。
- 不共享账号、不代理别人的流量；只用自己的账号恢复自己的出口会话。
- 不改变 DNS、代理、路由配置（路由器版唯一例外：可选的一次 WAN 重连，见下）。
- 是否允许“自动登录”取决于学校规定，使用前请自行确认。

## 工作原理

```
每 N 分钟：
  GET /api/account/status
      │
      ├─ 在线 ────────────────► 退出（不登录、不写日志）
      │
      └─ 离线
           GET /api/csrf-token  （拿 token + 会话 cookie）
           POST /api/account/login（账号/密码/nasId/可选 IP+MAC）
               │
               ├─ code 0 ──► 2 秒后复查状态：真在线才算成功
               ├─ code 1 ──► 退避重试（5→10→…→30 分钟）
               │              └─ 若报“设备IP不在线”且是网关路由器：
               │                 重连 WAN（15 分钟最多一次）→ 等 60 秒复查
               │                 → 仍离线再登录一次
               └─ code 2 ──► 需要验证码：停 30 分钟，记录，等人工
```

关键点：

1. **先查状态，在线绝不登录。** 很多门户接受“重复登录”的请求（返回成功），
   但随后会终止原会话，NAS 再报“设备IP不在线”——我们实际踩过。
2. **nasId 必须取 BRAS 重定向 URL 的值**（如 `acip=…&nasId=52`），
   门户 `/api/config` 的 `default_nas` 只是默认页，用错会一直报“设备IP不在线”。
3. **验证码策略**：`/api/config` 的 `err_count_captcha` 表示连续错误多少次才出验证码；
   脚本失败会退避，避免把账号打到触发验证码。
4. **凭据只存本机**：root/当前用户 600 的文件；不进仓库、日志、进程参数。
5. 所有运行时状态写在 `/tmp`（路由器）或 `%APPDATA%`（Windows），不磨损 NAND。

## 快速开始（OpenWrt / Linux 网关）

```sh
# 1. 拷贝脚本
scp bin/portal_autologin.sh bin/portal_set_credentials.sh root@router:/usr/bin/
ssh root@router 'chmod 755 /usr/bin/portal_autologin.sh /usr/bin/portal_set_credentials.sh'

# 2. 交互输入账号密码（密码不回显，只写 /etc/portal/login.conf，600）
ssh -t root@router /usr/bin/portal_set_credentials.sh

# 3. 设置门户地址和 NAS 号（NAS 号看未认证时浏览器被重定向的 URL）
export PORTAL_HOST=172.30.21.100          # 你的门户 IP
printf 'NAS_ID=52\n' > /etc/portal/nas.conf && chmod 600 /etc/portal/nas.conf

# 4. cron，每 3 分钟巡检（在线时静默）
echo '*/3 * * * * PORTAL_HOST=172.30.21.100 PORTAL_WAN_DEV=wan PORTAL_RECONNECT=1 /usr/bin/portal_autologin.sh run >/dev/null 2>&1' \
  >> /etc/crontabs/root

# 5. 验证
PORTAL_HOST=172.30.21.100 /usr/bin/portal_autologin.sh status
```

在路由器上，`PORTAL_WAN_DEV=wan` 用于读取 WAN IP/MAC 并允许“设备IP不在线”时的重连；
在普通 PC/服务器上留空即可（脚本省略 IP/MAC 字段，门户按来源 IP 认证）。

## Windows（beta）

```powershell
powershell -ExecutionPolicy Bypass -File bin\portal_autologin.ps1 setup     # 存 URL/账号/密码（DPAPI）
powershell -ExecutionPolicy Bypass -File bin\portal_autologin.ps1 status    # 只读检查
powershell -ExecutionPolicy Bypass -File bin\portal_autologin.ps1 run       # 掉线才登录
```

用任务计划程序每 3 分钟跑 `run` 即可。密码用 Windows DPAPI 加密，只能被当前用户解密。
PC 在 NAT 后面时，门户看到的是路由器的公网 IP，因此也能维持路由器的会话——前提是门户按
**来源 IP** 认证且不强制 MAC 绑定（见兼容性）。

## 配置项（环境变量）

| 变量 | 默认 | 说明 |
|---|---|---|
| `PORTAL_HOST` | 空 | 门户 IP/域名，必填 |
| `PORTAL_PORT` | `80` | 门户 HTTP 端口 |
| `PORTAL_CONF` | `/etc/portal/login.conf` | 凭据文件（600） |
| `PORTAL_NAS_CONF` | `/etc/portal/nas.conf` | `NAS_ID=…` |
| `PORTAL_WAN_DEV` | 空 | 网关路由器的 WAN 接口（空=不读 IP/MAC） |
| `PORTAL_RECONNECT` | `0` | `1` 时允许“设备IP不在线”后 ifdown/ifup WAN |
| `PORTAL_FORCE_LOGIN` | `0` | `test-login` 在线时强制登录（危险） |

## 日志与排错

日志：`/tmp/portal_autologin.log`（路由器）或 `%APPDATA%\campus-portal-autologin\autologin.log`。

| 现象 | 含义 | 处理 |
|---|---|---|
| `login OK and verified online` | 成功 | 无 |
| `login rejected (code 1, nas N): 您的设备IP不在线` | nasId 错 / NAS 需要链路重连 / 在线重复登录 | 核对 BRAS URL 的 nasId；必要时重连 WAN |
| `portal requires a captcha` | 门户要求验证码 | 人工登录一次；不要试图破解 |
| `portal returned no CSRF token` | 门户改版或不可达 | 检查门户地址/版本 |
| `session is online; refusing test-login` | 保护机制 | 正常 |

## 兼容性摘要

| 门户类型 | 结论 |
|---|---|
| srun/深澜 v5（`/api/account/*`，本实现） | 高：改 `PORTAL_HOST` + nasId 即可 |
| 老 srun（`/cgi-bin/srun_portal`、`srun_portal_pc`） | 低：参数/校验和不同，需要适配器 |
| Dr.COM、锐捷 ePortal 等 | 低：协议不同，需要新适配器 |
| 802.1X / 客户端认证 | 不适用 |
| 每次登录都要验证码 | 不适用（按设计停止） |
| HTTPS 门户 | 需 curl 变体（当前 nc 只支持 HTTP） |

完整评估、识别方法和迁移清单见 [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md)。

## 目录结构

```
bin/portal_autologin.sh         路由器/Linux 主程序（busybox ash）
bin/portal_set_credentials.sh   交互写凭据（600）
bin/portal_autologin.ps1        Windows PC 版（beta）
docs/DESIGN.md                  设计、状态机、决策与失败模式
docs/PROTOCOL.md                门户接口与协议细节
docs/COMPATIBILITY.md           迁移评估与适配指南
examples/                       配置样例
```

## 安全模型

- 密码只存在于 600 权限的凭据文件（或 Windows DPAPI 加密文件）；
- 日志只记录结果码、nasId、时间，不记录账号密码；
- 登录请求体不经过命令行参数，不出现在 `ps` 里；
- 任意时刻只允许一个实例（flock）；
- 不做端口扫描、不探测他人会话、不主动注销会话（测试除外，且需明确授权）。

## 免责声明

本项目与任何学校/厂商无关，仅用于自动化**自己的**合法登录。校园网使用条款可能禁止
自动登录；在部署前请确认学校规定，风险自负。

## 许可

MIT，见 [LICENSE](LICENSE)。
