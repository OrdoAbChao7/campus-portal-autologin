# 没有路由器：在电脑上实现自动认证

很多人只有一台电脑、没有常开的路由器。这个方案不需要额外硬件：**把脚本放在持有
校园网出口的那台设备上**，由它来维持会话。

## 1. 原理

- 门户按**来源 IP** 认证。谁发起的登录，就维持那个出口 IP 的会话。
- **电脑直连校园网**（有线或校园 Wi-Fi）：脚本维持电脑自己的会话。电脑上网不受影响。
- **电脑开“移动热点”**：热点下的手机/平板经过电脑 NAT，共用电脑的出口 IP，所以脚本
  同时保住了整屋设备——但电脑必须开机，休眠/关机就断。
- **手机单独连校园网**：本方案覆盖不到。不建议在手机上跑自动化脚本（没有稳定的脚本
  环境，第三方自动化工具也可能违反学校规定）。这种情况还是需要一个常开的设备。
- 如果电脑在**手机热点**后面：出口是手机的 IP，脚本在电脑上无法维持手机的会话。

## 2. Windows（推荐，beta）

### 2.1 准备

1. 拿到门户地址（如 `http://172.30.21.100`）。
2. 拿到 `nasId`：断网时用浏览器打开任意 HTTP 站点，会被重定向到
   `…/login.html?acip=…&nasId=NN&ip=…`，`NN` 就是。填错会一直报“设备IP不在线”。
3. 下载 `bin/portal_autologin.ps1`，放到一个固定目录（例如
   `%APPDATA%\campus-portal-autologin\portal_autologin.ps1`）。

### 2.2 保存账号

```powershell
powershell -ExecutionPolicy Bypass -File "%APPDATA%\campus-portal-autologin\portal_autologin.ps1" setup
```

密码用 Windows DPAPI 加密，只有当前 Windows 用户能解密；不会写进脚本或日志。

### 2.3 验证（只读）

```powershell
powershell -ExecutionPolicy Bypass -File "%APPDATA%\campus-portal-autologin\portal_autologin.ps1" status -NoProxy
```

- `-NoProxy`：本次进程绕过系统代理直连门户。**如果你的代理软件把门户也代理了，
  不加这个参数会超时**；更彻底的做法是在代理软件里给门户 IP/学校域名加 DIRECT。
- 电脑**直连**校园网时，可再加 `-SendClientInfo`，把本机 IPv4/MAC 一起发给门户
  （NAT 后面不要用，那个 IP/MAC 不是 NAS 看到的）。

### 2.4 定时执行（隐藏窗口）

每 3 分钟跑一次，没有控制台弹窗。先放一个 VBS 启动器：

```vbs
' %APPDATA%\campus-portal-autologin\run-hidden.vbs
Dim sh, fso, base, cmd
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
base = fso.BuildPath(sh.ExpandEnvironmentStrings("%APPDATA%"), "campus-portal-autologin")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & _
      fso.BuildPath(base, "portal_autologin.ps1") & """ run -NoProxy"
sh.Run cmd, 0, False
```

注册任务（当前用户，登录后运行，每 3 分钟）：

```powershell
schtasks /Create /SC MINUTE /MO 3 /TN "CampusPortalAutoLogin" ^
  /TR "wscript.exe \"%APPDATA%\campus-portal-autologin\run-hidden.vbs\"" ^
  /F
```

开机/登录即恢复一轮（可选）：把 `/SC MINUTE` 的任务再加一个“登录时”触发器，或另建
`/SC ONLOGON` 任务指向同一个 VBS。

> 关闭电脑或休眠 = 停止保活；唤醒后的下一轮会补登录。

## 3. Linux / macOS

用同一个 shell 脚本（`bin/portal_autologin.sh`，需要 `nc`；HTTPS 门户需要 curl 变体）：

```sh
PORTAL_HOST=172.30.21.100 PORTAL_CONF=$HOME/.config/campus-autologin/login.conf \
  sh portal_autologin.sh status
```

- Linux：`crontab -e` 加 `*/3 * * * * PORTAL_HOST=… sh /path/portal_autologin.sh run`。
- macOS：`launchd` 定时（StartInterval 180）或 `cron`。
- 凭据文件用 `bin/portal_set_credentials.sh` 交互写入（600）。

## 4. 让门户不被代理

- 这是“电脑上不工作”的最常见原因：代理软件把 `172.30.x.x` 或学校域名送进了海外节点，
  门户按来源 IP 重置，表现为超时/打不开。
- 二选一：
  1. PowerShell 版加 `-NoProxy`（进程级绕过）；
  2. 在代理软件里加规则：门户 IP 段、校园 WAN 网段、学校域名 → DIRECT。
- 浏览器手动登录时同理：先关代理，或给浏览器加同样的直连规则。

## 5. 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| 打开门户超时 | 代理软件拦截 | `-NoProxy` 或加 DIRECT |
| `login rejected … 您的设备IP不在线` | nasId 错 / 在线时重复登录 | 核对 BRAS URL 的 nasId；脚本已避免在线登录 |
| `portal requires a captcha` | 学校要求验证码 | 人工登录一次；不破解 |
| 睡眠后断网 | 保活停止 | 唤醒后下一轮恢复；或让电脑常开 |
| 手机和电脑互相踢下线 | 账号单设备限制 | 校园策略，脚本无法规避 |

## 6. 限制

- 只有跑脚本的电脑（及其热点）受益；手机单独连校园网时不受保护。
- 802.1X/专有客户端认证不适用。
- 电脑必须开机，且不能休眠到断网。
- 是否允许自动登录取决于学校规定。
