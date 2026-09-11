# DeepSeek Harness — Windows 双击启动器

让 **DeepSeek Harness**（`@deepseek-ai/dsh`）在桌面**双击直接打开，不需要管理员权限、不弹 UAC**，
使用官方黑色鲸鱼图标（**透明背景，不是白底**），并且**每次都在 Microsoft Edge 里新开一个标签页**——
包括服务已经在跑的时候：那就直接再开一个页面，而不是报「端口被占用」。

```
桌面快捷方式 → DeepSeekHarness.local.cmd → launch.ps1 → node.exe …\@deepseek-ai\dsh\lib\bin.js web --no-open
                                            ↓ 读出 dsh web 打印的认证 URL
                                        msedge.exe <URL>     每次都新开一个标签页
```

> English documentation is at the bottom: [English](#english).

---

## 目录

* [这个项目解决什么问题](#这个项目解决什么问题)
* [根因](#根因)
* [打开行为（Edge、新标签页、复用已运行的实例）](#打开行为edge新标签页复用已运行的实例)
* [安装教程](#安装教程)
* [装完之后有什么](#装完之后有什么)
* [图标是怎么做的](#图标是怎么做的)
* [设计说明（改文件前必看）](#设计说明改文件前必看)
* [排错](#排错)
* [安全说明](#安全说明)
* [如何上传到 GitHub](#如何上传到-github)
* [许可证](#许可证)

---

## 这个项目解决什么问题

最常见的做法是建一个快捷方式，内容是：

```
npx.cmd --verbose @deepseek-ai/dsh web
```

但这个快捷方式在**普通双击时会失败**，报 EPERM，只有**以管理员身份运行**才能打开：

```
npm error code EPERM
npm error syscall open
npm error path D:\NodeJS\node_cache\_cacache\tmp\5c9f727a
npm error The operation was rejected by your operating system.
npm error It's possible that the file was already in use ...
npm error or try running the command again as root/Administrator.
```

## 根因

`npx` 在**每一次启动**时都会去 npm registry 校验一遍包，并把结果写进它的缓存目录：

* `<npm-cache>\_cacache`（包缓存）
* `<npm-cache>\_logs`（调试日志）

而在「Node.js 装在整机目录」这种常见情况下，这些目录属于 `BUILTIN\Administrators`，
普通用户只有 `ReadAndExecute`：

```
D:\NodeJS\node_cache
  BUILTIN\Users                     ReadAndExecute, Synchronize
  NT AUTHORITY\Authenticated Users   ReadAndExecute, Synchronize
  BUILTIN\Administrators            FullControl
```

所以普通用户写不进去 → `npx` 以 `EPERM` 失败 → 用管理员身份一提升就有写权限，
于是表现为「必须管理员运行」。**这和快捷方式有没有勾"以管理员身份运行"完全无关。**

你可以自己验证这一点：那个开关是 `RunAsUser`，位于 `.lnk` 头部 **偏移 `0x15` 的 LinkFlags 第 `0x20` 位**。

```powershell
$b = [System.IO.File]::ReadAllBytes("$env:USERPROFILE\Desktop\你的快捷方式.lnk")
($b[0x15] -band 0x20) -ne 0     # 输出 True 才代表"以管理员身份运行"
```

## 解决办法

彻底跳过 npm/npx，直接用 `node.exe` 运行**已经装好的**包。
它不会往 npm 缓存里写任何东西，所以完全不需要提权：

```
node.exe "<npm-cache>\_npx\<hash>\node_modules\@deepseek-ai\dsh\lib\bin.js" web
```

---

## 打开行为（Edge、新标签页、复用已运行的实例）

浏览器这一段不在 `.cmd` 里，而在 `launch.ps1`：`.cmd` 负责探测路径，`launch.ps1` 负责开页面。
双击快捷方式后会发生三件事之一：

### 1. 服务已经在跑 → 只开一个新页面，不再启动第二个服务

`launch.ps1` 先探测 `127.0.0.1:<端口>`（默认 3080）。如果那里已经在跑一个 Harness 服务，
它就**不会**再启动一个（否则必然 `EADDRINUSE` 报错退出），而是直接在 Edge 里开一个新标签页连上去。

判定是精确的，靠两条只有 Harness 才会给出的响应，所以别的程序占了 3080 也不会被误认：

* `200` → 首页里带 `<title>DeepSeek Harness</title>`
* `401` → 页面正文是 `dsh web authentication required`

所以「已经开着控制台窗口，再双击一次快捷方式」= 又多一个页面，仅此而已。

> 这个页面用的是浏览器里的登录 Cookie（有效期 30 天，由第一次打开时写入）。
> 如果浏览器刚清过 Cookie，页面会提示要认证 —— 那就用已经开着的那个控制台窗口里打印的 URL。

### 2. 服务没在跑 → 启动它，并把**它打印的那个 URL**交给 Edge

```
node.exe …\dsh\lib\bin.js web --no-open      ← --no-open：不让 dsh 自己调用"默认浏览器"
   ↓ stdout 里出现 "dsh web: http://127.0.0.1:3080/?token=…"
msedge.exe "http://127.0.0.1:3080/?token=…"  ← 交给 Edge，明确是 Edge
```

* 用 `--no-open` 是因为「默认浏览器」不一定是 Edge；拿到 URL 后由我们交给 `msedge.exe`。
* `dsh web` 只在 stdout 打印那一行，所以 `launch.ps1` 捕获它的 stdout、逐行回显，读到 URL 就开页面。
  stderr 仍然直连控制台，因此启动报错照旧实时可见，也不会因为管道写满而死锁。
* URL 里的 `token` 只对**当前这个进程**有效，所以必须从输出里读，没法预先猜。

### 3. 每次都是「新标签页」

打开前会给 URL 加一个一次性的 `dsh-open=<时间戳>` 查询参数。Harness 服务端和前端都会忽略它，
但它让 URL 每次都不同 —— 这样 Edge 不会因为「这个 URL 已经开着」而去聚焦旧标签页，而是老实新开一个。

其他细节：

* **点两次、三次都有效**：每次都会多一个标签页，都连到同一个服务。
* **端口可以改**：`DeepSeekHarness.local.cmd --port 3099`，探测和打开都用这个端口。
* **没有 Edge 也不会挂**：只在真的找不到 `msedge.exe` 时才退回系统默认浏览器，并在控制台说明。
* **默认端口 3080，可以用 `--port 0`** 让系统随便挑一个空闲端口，这时跳过探测、直接用服务打印的 URL。

---

## 安装教程

按顺序做即可。第 1、2 步是准备，第 3 步开始才是真正的安装。

### 第 0 步 — 前置条件

* Windows 10 或 11
* 已安装 Node.js（`node --version` 能输出版本号）
* `dsh` 至少安装过一次（这样它才会存在于 npx 缓存里）

### 第 1 步 — 先安装一次 dsh

如果 `npx @deepseek-ai/dsh --version` 已经能输出版本号，跳过这步。

```powershell
npx @deepseek-ai/dsh --version
```

> 如果这里就报 `EPERM ... _cacache`，说明 npm 缓存目录普通用户没有写权限。
> 可以用管理员身份执行一次，或者把 npm 缓存改到自己的目录：
> ```powershell
> npm config set cache "$env:LOCALAPPDATA\npm-cache"
> ```
> 注意：**装好之后就不需要再用 npx 启动了**，这正是本启动器要绕开的问题。

### 第 2 步 — 获取本仓库

```powershell
git clone https://github.com/ZWQlearningpath/deepseek-harness-shortcut.git
cd deepseek-harness-shortcut
```

没装 git 的话，在 GitHub 页面点 **Code → Download ZIP**，解压到任意目录即可。

### 第 3 步 — 先干跑，确认能检测到路径（不写任何东西）

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -WhatIfOnly
```

正常应该看到类似：

```
==> Detecting Node.js
    C:\Program Files\nodejs\node.exe
==> Locating the installed dsh package
    C:\Users\<你>\AppData\Local\npm-cache\_npx\<hash>\node_modules\@deepseek-ai\dsh\lib\bin.js
==> Resolved settings
    ...
==> WhatIfOnly: nothing was written.
```

如果哪一项显示 *not found*，先解决它再继续（可用 `-NodeExe` / `-DshBin` 手动指定）。

### 第 4 步 — 正式安装

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

它会做四件事：

1. 生成 `DeepSeekHarness.local.cmd`（把检测到的 node / dsh / msedge / launch.ps1 路径填进去）
2. 生成 `deepseek-whale.ico`（桌面快捷方式图标）
3. **把已安装的 dsh 前端 `favicon.svg` 换成"永远是黑色鲸鱼"的版本**（浏览器标签页图标；
   原始文件备份成同目录的 `favicon.svg.orig`，详见[图标是怎么做的](#图标是怎么做的)）
4. 在桌面创建 **DeepSeek Harness** 快捷方式，并清除"以管理员身份运行"标志位

成功后最后一行会显示 `run-as-administrator flag set: False`。重复运行是安全的。

> 升级或重装 dsh 之后，`dist/favicon.svg` 会被新的包覆盖，第 3 步的效果就没了 ——
> 重新跑一次 `install.ps1` 即可。不想要这个改动就用 `-NoFaviconPatch`，
> 想还原就 `install.ps1 -RestoreFavicon`。
>
> **如果第 3 步提示 `NOT WRITABLE`**：npm 缓存目录属于 `BUILTIN\Administrators`（就是[根因](#根因)里
> 那种机器级 Node 安装，普通账号只有读权限），那就从**管理员** PowerShell 跑一次
> `install.ps1 -OnlyFavicon`（在仓库目录里跑）。这是**唯一**需要提权的一步 —— 双击启动、开 Edge、复用实例都不需要管理员。

### 第 5 步 — 使用

双击桌面上的 **DeepSeek Harness**。会弹出一个黑色命令行窗口，并在 **Microsoft Edge 里新开一个标签页**
（`http://127.0.0.1:3080`，标签页图标是黑色鲸鱼）。

**这个命令行窗口不要关**，关了服务器就停了。启动报错也会显示在这个窗口里。

再双击一次？服务已经在跑，所以**不会再启动第二个服务**，只是再开一个新的 Edge 标签页，
连到同一个服务 —— 不会出现"端口被占用"的报错。

### 第 6 步 — 验证确实不需要管理员权限（可选）

```powershell
$b = [System.IO.File]::ReadAllBytes("$env:USERPROFILE\Desktop\DeepSeek Harness.lnk")
($b[0x15] -band 0x20) -ne 0     # 必须输出 False
```

### 常见问题

| 现象 | 原因与处理 |
| --- | --- |
| PowerShell 拒绝运行脚本 | 用 `powershell -ExecutionPolicy Bypass -File .\install.ps1`，只对本次调用生效，不改系统策略 |
| 提示找不到 dsh 包 | dsh 还没装进 npx 缓存，回到第 1 步；或确认 `npm config get cache` 的目录 |
| 端口被占用 | 现在不会了：已有实例在跑就直接开一个新标签页连上去。想换个端口：`DeepSeekHarness.local.cmd --port 3099` |
| 页面提示需要认证 | 浏览器里没有登录 Cookie（清过、或换了浏览器配置）。用已经在跑的那个控制台窗口打印的 URL 打开一次即可，Cookie 有效期 30 天 |
| 标签页图标是白色鲸鱼 | 两种可能：① dsh 升级把前端 favicon 覆盖了，重跑一次 `install.ps1`；② npm 缓存属于 `Administrators`（见[根因](#根因)），补丁写不进去 —— 在仓库目录里用**管理员** PowerShell 跑一次 `install.ps1 -OnlyFavicon`。这是唯一需要提权的一步 |
| 打开的不是 Edge | 没找到 `msedge.exe`（控制台会说明）。装了 Edge 后重跑 `install.ps1`，或用 `-EdgeExe` 指定 |
| 桌面图标还是旧的 | Explorer 图标缓存，桌面按 **F5** 刷新 |
| 不想用脚本 | 直接双击 `DeepSeekHarness.cmd`，它运行时自动检测 Node 和 dsh（需要和 `launch.ps1` 在同一个文件夹里） |

### 完全不用脚本的手动安装

1. 把 `DeepSeekHarness.cmd` **和 `launch.ps1`** 放到一个固定文件夹
2. 右键 → **发送到 → 桌面快捷方式**
3. 右键快捷方式 → **属性**：*目标* 填该 `.cmd` 的完整路径，*起始位置* 填所在文件夹
4. 想换图标：先跑一次 `install.ps1 -NoShortcut` 生成 `deepseek-whale.ico`，
   再 **属性 → 更改图标 → 浏览** 选中它

### 卸载

1. 先还原前端 favicon（如果你不想留着黑色鲸鱼图标）：
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1 -RestoreFavicon
   ```
2. 删除桌面快捷方式
3. 删除 clone 下来的文件夹（含生成的 `deepseek-whale.ico`、`DeepSeekHarness.local.cmd`）
4. 没有写注册表，也没改任何系统设置 —— 唯一被改过的是前端那个 `favicon.svg`（第 1 步还原）

---

## 装完之后有什么

| 文件 | 作用 |
| --- | --- |
| `install.ps1` | 自动检测 Node + dsh + Edge，生成图标，写启动器、修 favicon、建桌面快捷方式 |
| `DeepSeekHarness.cmd` | 启动器入口。运行时自动检测 Node/dsh；`install.ps1` 也会把检测到的路径填进去。可单独双击 |
| `launch.ps1` | 浏览器交接：复用已运行的服务或启动新的，读 `dsh web` 打印的认证 URL，在 Edge 里新开标签页 |
| `assets/deepseek-whale.svg` | 官方鲸鱼矢量图，取自 dsh web 前端包 |
| `assets/deepseek-whale-black.svg` | 同一张图，去掉了官方"深色主题变白"的规则，用于修前端 favicon |
| `deepseek-whale.ico` | 由 `install.ps1` 生成（已 gitignore） |
| `DeepSeekHarness.local.cmd` | 由 `install.ps1` 生成（已 gitignore） |
| `legacy/` | 最初的、写死本机路径的版本，仅作参考，见 `legacy/README.md` |

### `install.ps1` 可用参数

| 参数 | 含义 |
| --- | --- |
| `-NodeExe <路径>` | 手动指定 `node.exe`，不用自动检测 |
| `-DshBin <路径>` | 手动指定 `...\@deepseek-ai\dsh\lib\bin.js` |
| `-EdgeExe <路径>` | 手动指定 `msedge.exe`，不用自动检测 |
| `-WorkDir <路径>` | 写进快捷方式的工作目录，默认是本仓库目录 |
| `-DesktopDir <路径>` | 快捷方式写到哪里，默认是桌面 |
| `-ShortcutName <名字>` | 快捷方式文件名（不含 `.lnk`），默认 `DeepSeek Harness` |
| `-NoShortcut` | 只生成图标、启动器和 favicon 补丁，不建快捷方式 |
| `-NoFaviconPatch` | 不动已安装 dsh 前端的 favicon（标签页图标恢复"深色主题变白"的官方行为） |
| `-OnlyFavicon` | 只修补前端 favicon（浏览器标签页图标），其他什么都不做 —— npm 缓存属于 Administrators 时，提权运行就用这一条 |
| `-RestoreFavicon` | 把前端原来的 `favicon.svg` 还原回去，其他什么都不做 |
| `-WhatIfOnly` | 只检测并打印，不写任何文件 |

想测试又不污染桌面时很好用：

```powershell
.\install.ps1 -DesktopDir .\out -ShortcutName 'DSH Test'
```

---

## 图标是怎么做的

没有去抠一张 51×46 位图的白色背景（那样在 16px 下会糊成一团），而是用 dsh web 前端包里
**自带的官方矢量 logo** 重新渲染
（`@deepseek-ai/dsh-web-frontend/dist/favicon.svg`）。

`install.ps1` 直接解析 SVG 的路径数据 —— 它只用了绝对 `M`/`C`/`Z`，所以**不需要任何 SVG 引擎** ——
再用 GDI+ 栅格化成 7 帧的 `.ico`：

```
16, 24, 32, 48, 64, 128, 256 像素    （PNG 压缩帧，保留 alpha 透明通道）
```

背景完全透明，只画黑色鲸鱼。另外用同样颜色的极细描边略微加粗字形，
让细长的尾鳍在 16px 下也能看清。

### 浏览器标签页图标（favicon）

标签页图标不是我们的文件，而是 **dsh 自己服务出去的** —— 服务端每次请求都从已安装的前端目录里
读 `dist/favicon.svg`（`@deepseek-ai/dsh-host-frontend-static`）。那个官方文件里有一条规则：

```svg
@media (prefers-color-scheme: dark) { path { fill: #fff; } }
```

也就是说：**浅色主题下是黑色鲸鱼，深色主题下会变成白色鲸鱼**。桌面快捷方式用的是 `.ico`，
永远是黑的；为了让标签页也一致，`install.ps1` 会把这一条规则去掉的版本
（`assets/deepseek-whale-black.svg`，路径数据与官方**完全一致**，只是没有那条媒体查询）
复制过去覆盖 `dist/favicon.svg`，覆盖前先把原文件备份成 `dist/favicon.svg.orig`。

* 幂等：内容一样就不重写；备份只做一次，之后不会被自己覆盖掉。
* 可还原：`install.ps1 -RestoreFavicon` 把 `.orig` 复制回去，别的不动。
* 会被覆盖：重装或升级 dsh 后前端是新解出来的，重跑一次 `install.ps1` 即可。
* 这是安装脚本**唯一**动到的仓库之外的文件，见[安全说明](#安全说明)。
* **可能唯一需要提权的一步**：npm 缓存目录属于 `BUILTIN\Administrators` 时（[根因](#根因)里那种
  机器级 Node 安装），普通账号连这个文件都改不了。`install.ps1` 会先探测写权限并明确提示
  `NOT WRITABLE`，这时在仓库目录里用**管理员** PowerShell 跑一次 `install.ps1 -OnlyFavicon`。启动器本身
  （双击、开 Edge、复用实例）永远不需要管理员。

### 为什么 `DrawIcon` 可能读不了生成的图标

`System.Drawing.Icon` / `Graphics.DrawIcon` **无法渲染 PNG 压缩的 ICO 帧**，
在这个文件上会抛 `ArgumentOutOfRangeException`。这是 GDI+ 的限制，
**不是图标损坏** —— Windows 资源管理器、任务栏、`System.Drawing.Image` 都能正常读取。
想检查各帧可以这样：

```powershell
$b = [System.IO.File]::ReadAllBytes('.\deepseek-whale.ico')
$n = [BitConverter]::ToUInt16($b,4)
0..($n-1) | ForEach-Object {
  $o = 6 + 16*$_
  $len = [BitConverter]::ToUInt32($b,$o+8); $off = [BitConverter]::ToUInt32($b,$o+12)
  $ms = New-Object System.IO.MemoryStream($b,$off,$len)
  $img = [System.Drawing.Image]::FromStream($ms)
  "frame $_ -> $($img.Width)x$($img.Height)"
}
```

---

## 设计说明（改文件前必看）

### 浏览器交接为什么必须用 PowerShell

`.cmd` 里做不了这件事。要把页面交给 **Edge**（而不是"默认浏览器"），就必须**读到 `dsh web` 打印的
认证 URL** —— 那个 `?token=…` 是每个进程随机生成的，只能从它的 stdout 里抓。批处理没有可靠的
"边读子进程输出边回显"的写法（`for /f` 会吃空行、还会被 `echo` 的特殊字符搞崩），所以这段逻辑在
`launch.ps1` 里，用 .NET 的 `ProcessStartInfo` + `RedirectStandardOutput` + `ReadLine()` 实现：

* **只重定向 stdout**（URL 在那里），stderr 直连控制台 —— 既不会因为没读另一个流而写满死锁，
  启动报错也照旧实时出现在窗口里。
* 逐行 `Write-Host` 回显，和真正的服务器输出没有区别。
* 句柄 `finally` 里保证不留孤儿服务：脚本被关掉时子进程一起结束。

### 参数一律走环境变量

`%*`（用户传给 `.cmd` 的参数）被写进 `DSH_ARGS`，其余路径也全部通过环境变量传给 `launch.ps1`，
**不进命令行**：

* PowerShell 会把命令行上的 `--port 3099` 当成自己的参数 `-port` 去绑定，直接报错；
* 更重要的是，非 ASCII 路径放在命令行上要经过 `cmd.exe` 的引号/代码页处理，环境变量是 UTF-16，安全。

`DSH_ARGS` 只是在 PowerShell 里被**原样拼**进子进程的命令行，不解析、不重新引用。

### `.cmd` 文件必须保持纯 ASCII

`cmd.exe` 解析批处理时是按**字节偏移**推进的，但解码用的是控制台代码页。
一旦出现 UTF-8 非 ASCII 字符（比如中文目录名），两者就会错位：
cmd 会在**行中间**重新同步，导致文件剩余部分被当成命令执行。最小复现：

```
@echo off
echo A
set "P=D:\资料\project"
echo set-P=%P%
echo done
```

在 GBK 控制台下以 UTF-8（无 BOM）文件运行，会得到
`'P' is not recognized as an internal or external command` —— `set` 那一行本身就被解析错了。

本项目的对应处理：

* `install.ps1` 只把**纯 ASCII** 路径替换进启动器，并在写完后校验生成文件里
  非 ASCII 字节数为 0，不为 0 就直接抛错。
* 非 ASCII 路径由启动器在运行时自动检测。
* 工作目录从不写进 `.cmd`，而是由快捷方式的"起始位置"承载 —— 那是 UTF-16 存储，安全。
* 需要手工覆盖时，请设置环境变量 `DSH_NODE_EXE` / `DSH_BIN` / `DSH_EDGE_EXE` /
  `DSH_WORKDIR` / `DSH_LAUNCH`，不要把非 ASCII 文本直接写进文件。

另一个相关陷阱：**Windows PowerShell 5.1 会把无 BOM 的 `.ps1` 当作 ANSI 读取**，
所以含非 ASCII 文本的无 BOM 脚本会被解码错。脚本源码要么保持 ASCII，
要么存成带 UTF-8 BOM 的文件。

### `WScript.Shell` 会自己加上"以管理员身份运行"

当快捷方式的目标是 `.cmd` 时，`WScript.Shell.Save()` 可能把 `RunAsUser` 标志位留下，
导致每次启动都弹 UAC。`install.ps1` 在保存后清除该位，并回读校验它为 `0`：

```powershell
$fs = [System.IO.File]::Open($lnk, 'Open', 'ReadWrite', 'None')
$fs.Position = 0x15
# 清除 LinkFlags 的 0x20 位（RunAsUser）
```

---

## 排错

**命令行窗口不能关。** 关了服务器就停了。启动错误也显示在这个窗口里，
比过去"一闪而过"好排查得多。

**端口被占用。** 已经不会失败了。`dsh web` 默认用 `3080`；如果那里已经有一个 Harness 实例，
启动器不再去抢端口，而是直接**新开一个 Edge 标签页**连上去（见[打开行为](#打开行为edge新标签页复用已运行的实例)）。
想同时跑两个互相独立的实例，给其中一个换端口：

```
DeepSeekHarness.local.cmd --port 3099
```

**标签页提示需要认证。** 连到已运行实例时，页面靠 Cookie 认证（30 天）。浏览器清过 Cookie、
或者换了浏览器配置时会看到 401 页面，用已经在跑的那个控制台窗口打印的 URL 打开一次就行。

**桌面图标还是旧的。** Explorer 会缓存图标，在桌面按 **F5** 刷新。

**提示找不到 dsh 包。** 包还没进 npx 缓存：

```powershell
npx @deepseek-ai/dsh --version
```

**升级 dsh。** `npx` 会遇到同样的 `EPERM`，所以要么用管理员身份升级，
要么把 npm 缓存指到可写目录（一次性设置）：

```powershell
npm config set cache "$env:LOCALAPPDATA\npm-cache"
```

`install.ps1` 的检测逻辑会跟随 `npm config get cache`，所以会自动适配。
重复运行 `install.ps1` 是安全的，它只覆盖自己生成的文件和快捷方式。

---

## 安全说明

启动器做的事，就是让 `node.exe` 去跑你 npm 缓存里的那个 `bin.js`。
那正是 `npx @deepseek-ai/dsh web` 会跑的同一份代码 —— 本仓库只改变**启动方式**，
不改变**运行内容**。运行前可以自己看一眼 `DeepSeekHarness.cmd`、`launch.ps1` 和 `install.ps1`，
三个文件都很短且有注释。

三个文件都是自包含的：不下载任何东西、没有遥测，也不含任何凭据、
用户名或本机专属路径 —— 所有路径都是运行时探测的。

**唯一动到仓库之外的东西**是浏览器标签页图标那一步（可以用 `-NoFaviconPatch` 关掉）：

* 只写一个文件：已安装的 `@deepseek-ai/dsh-web-frontend/dist/favicon.svg`；
* 覆盖前把它备份成同目录的 `favicon.svg.orig`，`-RestoreFavicon` 可以还原；
* 写进去的内容就是仓库里那个 `assets/deepseek-whale-black.svg`，路径数据与官方文件逐字节相同，
  只少了"深色主题变白"那一条媒体查询 —— 可以自己 diff；
* 它同时也是**唯一可能要求管理员权限**的步骤：npm 缓存属于 Administrators 时（见[根因](#根因)），
  安装脚本会报 `NOT WRITABLE` 并提示你提权跑一次；用 `-NoFaviconPatch` 可以完全跳过。

启动认证 URL 的处理也值得一提：`launch.ps1` 只是把 `dsh web` 打印到 stdout 的那一行
原样交给 `msedge.exe`。**URL（含 token）不落盘、不写日志、不传给任何别的程序**，
子进程的环境还经过 dsh 自己的 `scrubbedParentEnv()` 处理。

---

## 如何上传到 GitHub

仓库已经在本地建好了（有提交历史），只差推送。

### 方式 A：GitHub Desktop（推荐，不用敲命令）

1. 安装 GitHub Desktop：
   ```powershell
   winget install GitHub.GitHubDesktop
   ```
   或者到 https://desktop.github.com 下载安装。
2. 打开 GitHub Desktop，点 **Sign in to GitHub.com**，用浏览器登录你的账号
   （弹浏览器时选 `ZWQlearningpath`）。
3. 登录后点菜单 **File → Add local repository...**，选择文件夹：
   ```
   D:\GitWarehouse\deepseek-harness-shortcut
   ```
4. 它会识别出这是一个 git 仓库，界面显示 **No local changes**（因为已经提交过了）。
5. 点右上角 **Publish repository**：
   * **Name** 填 `deepseek-harness-shortcut`
   * **Description** 可留空或随便填
   * **取消勾选** `Keep this code private`（想要私有就保持勾选）
6. 点 **Publish repository**。完成 —— 之后网址是：
   ```
   https://github.com/ZWQlearningpath/deepseek-harness-shortcut
   ```

以后改了文件，Desktop 里会列出改动，填一句说明点 **Commit to main**，
再点 **Push origin** 就同步上去了。

### 方式 B：命令行（先建空仓库）

1. 打开 https://github.com/new
2. **Repository name** 填 `deepseek-harness-shortcut`
3. **不要**勾选 `Add a README file`、`.gitignore`、`license`（勾了就得先 pull，容易出错）
4. 点 **Create repository**
5. 然后在 PowerShell 里执行：
   ```powershell
   cd D:\GitWarehouse\deepseek-harness-shortcut
   git push -u origin main
   ```
6. 会弹出一个浏览器窗口让你登录 GitHub 授权（Git Credential Manager），
   选 `ZWQlearningpath` 登录即可。

> **不需要密码，也不需要 Token。**
> GitHub 从 2021 年起已禁止用账号密码做 git 操作；你这台机器的 git 已配置
> Git Credential Manager，会走浏览器 OAuth 授权，密码不经过任何第三方。

### 方式 C：网页直接拖文件（完全不用 git）

适合只想把文件放上去、不关心提交历史的情况：

1. 先在 https://github.com/new 建一个**空**仓库（同方式 B 的第 2～4 步）
2. 在仓库页面点 **uploading an existing file**
3. 把 `D:\GitWarehouse\deepseek-harness-shortcut` 里的这些**文件**拖进去：
   * `README.md`
   * `LICENSE`
   * `install.ps1`
   * `DeepSeekHarness.cmd`
   * `launch.ps1`
   * `.gitattributes`
   * `.gitignore`
   * `assets` 文件夹（里面有 `deepseek-whale.svg`、`deepseek-whale-black.svg`）
   * `legacy` 文件夹（里面有 `DeepSeekHarness-launcher.cmd`、`README.md`）
4. 下方填一句提交说明，点 **Commit changes**

> 注意：`deepseek-whale.ico` 和 `DeepSeekHarness.local.cmd` 是**本机生成**的，
> 已在 `.gitignore` 里，不用上传（别人 clone 后跑一次 `install.ps1` 就会生成）。

### 上传后建议检查

* 仓库根目录能看到 `README.md`，打开后中文正常显示
* 别人 clone 下来能按 README 跑通 `install.ps1`

---

## 许可证

MIT — 见 [LICENSE](LICENSE)。

---
---

# English

## DeepSeek Harness — double-click launcher for Windows

Makes **DeepSeek Harness** (`@deepseek-ai/dsh`) open with a plain double-click on
the desktop — **no administrator rights, no UAC prompt** — and gives the
shortcut the official black whale icon on a **transparent background**. Every
launch opens a **new Microsoft Edge tab**, including when a server is already
running: then you simply get another page instead of a "port already in use"
error.

```
Desktop shortcut → DeepSeekHarness.local.cmd → launch.ps1 → node.exe …\@deepseek-ai\dsh\lib\bin.js web --no-open
                                                 ↓ reads the authenticated URL dsh web prints
                                             msedge.exe <URL>     a new tab every time
```

## The problem this solves

The obvious shortcut is:

```
npx.cmd --verbose @deepseek-ai/dsh web
```

That shortcut fails on a normal double-click with an EPERM error, and only works
if you run it **as administrator**:

```
npm error code EPERM
npm error syscall open
npm error path D:\NodeJS\node_cache\_cacache\tmp\5c9f727a
npm error The operation was rejected by your operating system.
npm error It's possible that the file was already in use ...
npm error or try running the command again as root/Administrator.
```

### Root cause

`npx` revalidates the requested package against the npm registry **on every
single start**, and writes the response into its package cache
(`<npm-cache>\_cacache`) plus a debug log into `<npm-cache>\_logs`.

On a typical machine-wide Node.js install those cache directories are owned by
`BUILTIN\Administrators` and grant ordinary users only `ReadAndExecute`:

```
D:\NodeJS\node_cache
  BUILTIN\Users                     ReadAndExecute, Synchronize
  NT AUTHORITY\Authenticated Users   ReadAndExecute, Synchronize
  BUILTIN\Administrators            FullControl
```

So a standard user cannot write the cache, `npx` dies with `EPERM`, and
elevating to Administrator "fixes" it — which is exactly the symptom.

This has **nothing** to do with the shortcut being flagged as
administrator-only. You can confirm the flag yourself: it is `RunAsUser`,
LinkFlags bit `0x20` at byte offset `0x15` of the `.lnk` header.

```powershell
$b = [System.IO.File]::ReadAllBytes("$env:USERPROFILE\Desktop\YourShortcut.lnk")
($b[0x15] -band 0x20) -ne 0     # $true means "run as administrator"
```

### The fix

Skip npm/npx completely and run the **already-installed** package with
`node.exe`. Nothing is written outside your own profile, so no elevation is
needed:

```
node.exe "<npm-cache>\_npx\<hash>\node_modules\@deepseek-ai\dsh\lib\bin.js" web
```

## Launch behaviour (Edge, a new tab, reuse of a running instance)

The browser half lives in `launch.ps1`, not in the `.cmd`: the `.cmd` detects
paths, `launch.ps1` opens pages. A double-click ends in one of two ways.

### 1. A server is already running → another page, no second server

`launch.ps1` probes `127.0.0.1:<port>` (3080 by default). If a Harness server
answers there it does **not** start a second one (that would only die with
`EADDRINUSE`) — it just opens a new Edge tab on the instance that is running.

The probe only accepts two responses, both of which only the Harness produces, so
an unrelated program squatting on 3080 is never mistaken for it:

* `200` → the index page carries `<title>DeepSeek Harness</title>`
* `401` → the body is `dsh web authentication required`

So "console window still open, double-click again" costs you one extra page and
nothing else.

> That page authenticates with the browser cookie (30 days, written on the first
> visit). If the browser's cookies were just cleared you will see the
> authentication notice — use the URL printed by the console window that is
> already running.

### 2. No server → start one and hand its own URL to Edge

```
node.exe …\dsh\lib\bin.js web --no-open       ← --no-open: dsh does not call the "default browser"
   ↓ stdout: "dsh web: http://127.0.0.1:3080/?token=…"
msedge.exe "http://127.0.0.1:3080/?token=…"   ← handed to Edge, explicitly Edge
```

* `--no-open`, because the default browser is not necessarily Edge; once the URL
  is known *we* hand it to `msedge.exe`.
* `dsh web` only prints that line to stdout, so `launch.ps1` captures its stdout,
  echoes it line by line, and opens the page when the URL appears. stderr stays
  attached to the console, so startup errors remain visible in real time and
  neither pipe can fill up and deadlock.
* The `token` in the URL is valid for **that process only**, so it has to be read
  out of the output; it cannot be predicted.

### 3. Always a new tab

Before opening, a one-shot `dsh-open=<ticks>` query parameter is appended. Both
the Harness server and the Web client ignore it, but it makes the URL differ every
time — so Edge cannot decide "that URL is already open" and re-activate an old tab
instead of opening a new one.

Other details:

* **Double-click twice, three times — it works**: one more tab each time, all on
  the same server.
* **The port is flexible**: `DeepSeekHarness.local.cmd --port 3099` probes and
  opens on that port.
* **No Edge is not fatal**: only then does it fall back to the default browser,
  and it says so in the console.
* **`--port 0`** lets the OS pick a free port; the probe is skipped and the URL
  the server prints is used directly.

## Installation

> 中文用户请直接看上面的 [安装教程](#安装教程)。

Follow these steps in order. Steps 1 and 2 are prerequisites; step 3 onwards is
the actual install.

### Step 0 — what you need

* Windows 10 or 11
* Node.js installed (`node --version` should print a version)
* `dsh` installed at least once, so it exists in the npx cache

### Step 1 — install dsh once

Skip this if `npx @deepseek-ai/dsh --version` already prints a version.

```powershell
npx @deepseek-ai/dsh --version
```

> If this fails with `EPERM ... _cacache`, see
> [Troubleshooting](#troubleshooting) — you may need to run it once from an
> elevated console, or point npm at a writable cache. This is the very problem
> the launcher exists to avoid *afterwards*.

### Step 2 — get this repository

```powershell
git clone https://github.com/ZWQlearningpath/deepseek-harness-shortcut.git
cd deepseek-harness-shortcut
```

No git? Use **Code → Download ZIP** on GitHub and unpack it anywhere.

### Step 3 — check what the installer detects (writes nothing)

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -WhatIfOnly
```

Expected output:

```
==> Detecting Node.js
    C:\Program Files\nodejs\node.exe
==> Locating the installed dsh package
    C:\Users\<you>\AppData\Local\npm-cache\_npx\<hash>\node_modules\@deepseek-ai\dsh\lib\bin.js
==> Resolved settings
    ...
==> WhatIfOnly: nothing was written.
```

If either path says *not found*, fix that before continuing (pass `-NodeExe` /
`-DshBin`, or redo step 1).

### Step 4 — install

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

This:

1. writes `DeepSeekHarness.local.cmd` (your detected node / dsh / msedge /
   launch.ps1 paths filled in),
2. builds `deepseek-whale.ico`,
3. **replaces the installed dsh frontend's `favicon.svg` with an always-black
   whale** (the browser tab icon; the original is kept as `favicon.svg.orig` —
   see [The icon](#the-icon)),
4. creates the **DeepSeek Harness** shortcut on your desktop and clears its
   "run as administrator" bit.

It prints `run-as-administrator flag set: False` on success. Re-running it is
safe.

> Upgrading or reinstalling dsh unpacks a fresh frontend, so step 3 is undone —
> run `install.ps1` again. Pass `-NoFaviconPatch` to skip it, or
> `install.ps1 -RestoreFavicon` to put the original back.
>
> **If step 3 reports `NOT WRITABLE`**: the npm cache belongs to
> `BUILTIN\Administrators` (the machine-wide Node.js install described under
> [Root cause](#root-cause), where ordinary accounts can only read), so run
> `install.ps1 -OnlyFavicon` (from the repository folder) once from an **elevated**
> PowerShell. That is the
> **only** step that ever needs administrator rights — double-clicking, opening
> Edge and reusing a running instance never do.

### Step 5 — use it

Double-click **DeepSeek Harness** on your desktop. A console window opens and a
**new Microsoft Edge tab** lands on `http://127.0.0.1:3080` with the black whale
as its tab icon.

**Keep that console window open** — closing it stops the server. It is also
where startup errors appear.

Double-click it again and, because the server is already running, **no second
server starts**: you just get one more Edge tab on the same instance — never a
"port already in use" error.

### Step 6 — verify it really needs no admin rights (optional)

```powershell
$b = [System.IO.File]::ReadAllBytes("$env:USERPROFILE\Desktop\DeepSeek Harness.lnk")
($b[0x15] -band 0x20) -ne 0     # must print False
```

### If PowerShell refuses to run the script

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

That bypass applies to this one invocation only; it does not change any machine
or user policy.

Or skip the installer entirely: double-click **`DeepSeekHarness.cmd`**. It
auto-detects Node and the dsh package at start-up, `launch.ps1` (which must sit
next to it) opens Edge, and it will not create a desktop shortcut or the icon.

### Manual install (no script at all)

1. Pick a folder, put `DeepSeekHarness.cmd` **and `launch.ps1`** in it.
2. Right-click it → **Send to → Desktop (create shortcut)**.
3. Right-click the new shortcut → **Properties**:
   * *Target*: the full path to `DeepSeekHarness.cmd`
   * *Start in*: the folder you chose
4. To set the icon: run `install.ps1 -NoShortcut` once to generate
   `deepseek-whale.ico`, then **Properties → Change Icon → Browse** and pick it.

### Uninstall

1. Put the frontend's favicon back first, unless you want to keep the black whale:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1 -RestoreFavicon
   ```
2. Delete the desktop shortcut.
3. Delete the folder you cloned (and the generated `deepseek-whale.ico` /
   `DeepSeekHarness.local.cmd` inside it).
4. Nothing was written to the registry, and no system setting was changed — the
   only file touched outside this repo is the frontend's `favicon.svg` (step 1).

## What you get

| File | Purpose |
| --- | --- |
| `install.ps1` | Auto-detects Node + dsh + Edge, builds the icon, writes the launcher, patches the favicon and creates the desktop shortcut. |
| `DeepSeekHarness.cmd` | The launcher entry point. Auto-detects Node/dsh; `install.ps1` also bakes in the detected paths. Double-clickable on its own. |
| `launch.ps1` | The browser hand-off: reuse a running server or start one, read the authenticated URL `dsh web` prints, open it in a new Edge tab. |
| `assets/deepseek-whale.svg` | Official whale logo, taken from the dsh web frontend bundle. |
| `assets/deepseek-whale-black.svg` | The same artwork with the official "turn white on a dark theme" rule removed; used for the favicon patch. |
| `deepseek-whale.ico` | Generated by `install.ps1` (git-ignored). |
| `DeepSeekHarness.local.cmd` | Generated by `install.ps1` (git-ignored). |
| `legacy/` | The first, machine-specific version of the launcher, kept for reference. See `legacy/README.md`. |

### `install.ps1` options

| Option | Meaning |
| --- | --- |
| `-NodeExe <path>` | Use a specific `node.exe` instead of auto-detecting. |
| `-DshBin <path>` | Use a specific `...\@deepseek-ai\dsh\lib\bin.js`. |
| `-EdgeExe <path>` | Use a specific `msedge.exe` instead of auto-detecting. |
| `-WorkDir <path>` | Working directory recorded in the shortcut. Defaults to this repo folder. |
| `-DesktopDir <path>` | Where to write the shortcut. Defaults to your Desktop. |
| `-ShortcutName <name>` | Shortcut filename without `.lnk`. Defaults to `DeepSeek Harness`. |
| `-NoShortcut` | Build the icon, launcher and favicon patch only. |
| `-NoFaviconPatch` | Leave the installed frontend's favicon alone (the tab icon goes back to the official white-on-dark behaviour). |
| `-OnlyFavicon` | Patch the frontend favicon (the browser tab icon) and do nothing else - the command for the single elevated run when the npm cache belongs to Administrators. |
| `-RestoreFavicon` | Put the frontend's original `favicon.svg` back and do nothing else. |
| `-WhatIfOnly` | Detect and report; write nothing. |

Handy for testing without touching your desktop:

```powershell
.\install.ps1 -DesktopDir .\out -ShortcutName 'DSH Test'
```

## The icon

Rather than cutting the white background out of a small raster image (which
looks terrible at 16 px), the icon is rebuilt from the **official vector logo**
that ships inside the dsh web frontend
(`@deepseek-ai/dsh-web-frontend/dist/favicon.svg`).

`install.ps1` parses the SVG path — it is pure absolute `M`/`C`/`Z`, so no SVG
engine is required — and rasterises it with GDI+ into a 7-frame `.ico`:

```
16, 24, 32, 48, 64, 128, 256 px    (PNG-compressed frames, alpha preserved)
```

The background is fully transparent; only the black whale is drawn. A hairline
outline in the same black slightly fattens the glyph so the thin flukes stay
legible at 16 px.

### The browser tab icon (favicon)

The tab icon is not our file: **dsh serves it**, reading `dist/favicon.svg` from
the installed frontend on every request (`@deepseek-ai/dsh-host-frontend-static`).
The official file contains

```svg
@media (prefers-color-scheme: dark) { path { fill: #fff; } }
```

which means **black whale on a light theme, white whale on a dark theme**. The
desktop shortcut's `.ico` is always black, so `install.ps1` makes the tab match:
it copies the version without that media query
(`assets/deepseek-whale-black.svg` — the path data is byte-identical to the
official file) over `dist/favicon.svg`, keeping the original next to it as
`dist/favicon.svg.orig`.

* Idempotent: identical content is not rewritten, and the backup is only taken
  once, so the backup can never be overwritten by our own file.
* Reversible: `install.ps1 -RestoreFavicon` copies `.orig` back and touches
  nothing else.
* Overwritten by upgrades: reinstalling or upgrading dsh unpacks a fresh
  frontend, so run `install.ps1` again.
* It is the **only** file outside this repository that the installer writes; see
  the [Security note](#security-note).
* **It may be the one step that needs elevation**: when the npm cache belongs to
  `BUILTIN\Administrators` (the machine-wide Node.js install described under
  [Root cause](#root-cause)) an ordinary account cannot write this file at all.
  `install.ps1` probes for write access first and says `NOT WRITABLE`; run
  `install.ps1 -OnlyFavicon` once from an elevated PowerShell. The launcher itself
  — double-click, Edge, reuse — never needs administrator rights.

### Why `DrawIcon` may fail on the generated file

`System.Drawing.Icon` / `Graphics.DrawIcon` cannot render PNG-compressed ICO
frames and throws `ArgumentOutOfRangeException` on this file. That is a GDI+
limitation, **not** a corrupt icon — Windows Explorer, the taskbar and
`System.Drawing.Image` all read it correctly. To inspect the frames:

```powershell
$b = [System.IO.File]::ReadAllBytes('.\deepseek-whale.ico')
$n = [BitConverter]::ToUInt16($b,4)
0..($n-1) | ForEach-Object {
  $o = 6 + 16*$_
  $len = [BitConverter]::ToUInt32($b,$o+8); $off = [BitConverter]::ToUInt32($b,$o+12)
  $ms = New-Object System.IO.MemoryStream($b,$off,$len)
  $img = [System.Drawing.Image]::FromStream($ms)
  "frame $_ -> $($img.Width)x$($img.Height)"
}
```

## Design notes (things that will bite you if you edit these files)

### Why the browser hand-off has to be PowerShell

A `.cmd` cannot do it. Handing the page to **Edge** (rather than to the "default
browser") means **reading the authenticated URL `dsh web` prints** — that
`?token=…` is generated per process and only ever exists in its stdout. Batch has
no reliable "stream a child's output while echoing it" construct (`for /f` drops
blank lines and breaks on `echo`'s special characters), so that part lives in
`launch.ps1` and uses .NET's `ProcessStartInfo` with
`RedirectStandardOutput` + `ReadLine()`:

* **Only stdout is redirected** (the URL is there); stderr stays attached to the
  console — no unread pipe can fill up and deadlock, and startup errors still
  appear live in the window.
* Every line is echoed with `Write-Host`, indistinguishable from the real
  server's output.
* A `finally` block guarantees no orphan server: if the script is torn down, the
  child goes with it.

### Arguments always travel through the environment

`%*` (the arguments the user passed to the `.cmd`) is stored in `DSH_ARGS`, and
every path reaches `launch.ps1` through the environment, **never through a
command line**:

* PowerShell would bind a command-line `--port 3099` to its own `-port`
  parameter and fail outright;
* more importantly, a non-ASCII path on a command line has to survive `cmd.exe`
  quoting and code-page decoding, while an environment variable is UTF-16 and
  therefore safe.

`DSH_ARGS` is only ever **concatenated verbatim** into the child's command line —
never parsed, never re-quoted.

### The `.cmd` files must stay pure ASCII

`cmd.exe` parses a batch file **by byte offset** while decoding it using the
console code page. A UTF-8 non-ASCII character — a Chinese folder name, for
instance — makes those two disagree: cmd resynchronises in the middle of a line
and mis-executes the remainder of the file. A minimal reproduction:

```
@echo off
echo A
set "P=D:\资料\project"
echo set-P=%P%
echo done
```

Run from a UTF-8 (no BOM) file on a GBK console and you get
`'P' is not recognized as an internal or external command` — the `set` line
itself was mis-parsed.

Consequences, all handled here:

* `install.ps1` only substitutes **ASCII** paths into the launcher, and then
  verifies the generated file contains zero non-ASCII bytes.
* Non-ASCII paths are found by the launcher's own auto-detection at run time.
* The working directory is never embedded in the `.cmd`; the shortcut carries it
  in its "Start in" field, which is stored as UTF-16 and therefore safe.
* To override anything by hand, set `DSH_NODE_EXE`, `DSH_BIN`, `DSH_EDGE_EXE`,
  `DSH_WORKDIR` or `DSH_LAUNCH` in the environment rather than editing non-ASCII
  text into the file.

A related trap: **Windows PowerShell 5.1 reads BOM-less `.ps1` files as ANSI**,
so a BOM-less script containing non-ASCII text is mis-decoded. Keep script
sources ASCII, or save them with a UTF-8 BOM.

### `WScript.Shell` sets the "run as administrator" bit

When a shortcut's target is a `.cmd`, `WScript.Shell.Save()` may leave the
`RunAsUser` flag set, which forces a UAC prompt on every launch. `install.ps1`
clears it after saving and then verifies the bit is `0`:

```powershell
$fs = [System.IO.File]::Open($lnk, 'Open', 'ReadWrite', 'None')
$fs.Position = 0x15
# clear LinkFlags bit 0x20 (RunAsUser)
```

## Troubleshooting

**The console window must stay open.** Closing it stops the server. It is also
where startup errors appear, which makes failures far easier to diagnose than a
window that flashes and vanishes.

**Port already in use.** That no longer fails. `dsh web` defaults to port `3080`;
if a Harness instance already holds it, the launcher does not fight for the port —
it opens **another Edge tab** on the running instance (see
[Launch behaviour](#launch-behaviour-edge-a-new-tab-reuse-of-a-running-instance)).
To run two genuinely independent instances, give one of them a different port:

```
DeepSeekHarness.local.cmd --port 3099
```

**The tab asks for authentication.** When attaching to a running instance the page
authenticates with a cookie (30 days). After clearing cookies, or in a different
browser profile, you get the 401 page — open the URL printed by the console
window that is already running, once.

**The tab icon is a white whale.** Either an upgrade replaced the frontend's
`favicon.svg` (run `install.ps1` again), or the npm cache belongs to
`Administrators` (see [Root cause](#root-cause)) and the patch could not be
written — run `install.ps1 -OnlyFavicon` once from an elevated PowerShell. That is
the only step that needs elevation.

**The desktop icon still looks like the old one.** Explorer caches icons; press
**F5** on the desktop.

**"could not find the dsh package".** The package is not in the npx cache yet:

```powershell
npx @deepseek-ai/dsh --version
```

**Upgrading dsh.** `npx` hits the same `EPERM` problem, so update from an
elevated console, or point npm at a writable cache once:

```powershell
npm config set cache "$env:LOCALAPPDATA\npm-cache"
```

`install.ps1`'s detector follows `npm config get cache`, so it picks that up
automatically.

**Re-running `install.ps1` is safe.** It overwrites only the generated files and
the shortcut.

## Security note

The launcher executes `node.exe` against a `bin.js` path inside your npm cache.
That is the same code `npx @deepseek-ai/dsh web` would run — this repo only
changes *how* it is started, not *what* is started. Review `DeepSeekHarness.cmd`,
`launch.ps1` and `install.ps1` before running them; all three are short and
commented.

All three are self-contained: no downloads, no telemetry, and no credentials,
usernames or machine-specific paths. Every path is detected at run time.

**The one thing outside this repository** the installer writes is the browser tab
icon (skip it with `-NoFaviconPatch`):

* a single file: the installed
  `@deepseek-ai/dsh-web-frontend/dist/favicon.svg`;
* the original is backed up next to it as `favicon.svg.orig`, and
  `-RestoreFavicon` puts it back;
* what gets written is the repository's
  `assets/deepseek-whale-black.svg`, whose path data is byte-identical to the
  official file minus the "turn white on a dark theme" media query — diff it
  yourself;
* it is also the only step that may require administrator rights: when the npm
  cache is Administrators-owned (see [Root cause](#root-cause)) the installer
  reports `NOT WRITABLE` and points at a single elevated run; skip it entirely
  with `-NoFaviconPatch`.

The authenticated URL deserves a note too: `launch.ps1` only takes the line
`dsh web` printed on stdout and hands it to `msedge.exe`. **The URL (token
included) is never written to disk, never logged, and never passed to anything
else**, and the child's environment is the one dsh's own `scrubbedParentEnv()`
produces.

## License

MIT — see [LICENSE](LICENSE).
