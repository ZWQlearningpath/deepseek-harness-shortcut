# DeepSeek Harness — double-click launcher for Windows

Makes **DeepSeek Harness** (`@deepseek-ai/dsh`) open with a plain double-click on
the desktop — **no administrator rights, no UAC prompt** — and gives the
shortcut the official black whale icon on a **transparent background**.

```
Desktop shortcut  →  DeepSeekHarness.local.cmd  →  node.exe  …\@deepseek-ai\dsh\lib\bin.js web
```

---

## 中文安装教程

让 DeepSeek Harness（`@deepseek-ai/dsh`）在桌面**双击直接打开，不需要管理员权限、不弹 UAC**，
并使用官方黑色鲸鱼图标（**透明背景，不是白底**）。

### 第 0 步 — 前置条件

* Windows 10 / 11
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

它会做三件事：

1. 生成 `DeepSeekHarness.local.cmd`（把检测到的路径填进去）
2. 生成 `deepseek-whale.ico`
3. 在桌面创建 **DeepSeek Harness** 快捷方式，并清除"以管理员身份运行"标志位

成功后最后一行会显示 `run-as-administrator flag set: False`。重复运行是安全的。

### 第 5 步 — 使用

双击桌面上的 **DeepSeek Harness**。会弹出一个黑色命令行窗口，浏览器自动打开
`http://127.0.0.1:3080`。

**这个命令行窗口不要关**，关了服务器就停了。启动报错也会显示在这个窗口里。

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
| 提示端口被占用 | 已有实例在跑（默认 3080）。换端口：`DeepSeekHarness.local.cmd --port 3099` |
| 桌面图标还是旧的 | Explorer 图标缓存，桌面按 **F5** 刷新 |
| 不想用脚本 | 直接双击 `DeepSeekHarness.cmd`，它运行时自动检测 Node 和 dsh |

### 完全不用脚本的手动安装

1. 把 `DeepSeekHarness.cmd` 放到一个固定文件夹
2. 右键 → **发送到 → 桌面快捷方式**
3. 右键快捷方式 → **属性**：*目标* 填该 `.cmd` 的完整路径，*起始位置* 填所在文件夹
4. 想换图标：先跑一次 `install.ps1 -NoShortcut` 生成 `deepseek-whale.ico`，
   再 **属性 → 更改图标 → 浏览** 选中它

### 卸载

1. 删除桌面快捷方式
2. 删除 clone 下来的文件夹（含生成的 `deepseek-whale.ico`、`DeepSeekHarness.local.cmd`）
3. 没有写注册表，也没改任何系统设置

---

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

---

## Installation

> 中文用户请直接看上面的 [中文安装教程](#中文安装教程)。

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
git clone https://github.com/<you>/deepseek-harness-shortcut.git
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

1. writes `DeepSeekHarness.local.cmd` (your detected paths filled in),
2. builds `deepseek-whale.ico`,
3. creates the **DeepSeek Harness** shortcut on your desktop and clears its
   "run as administrator" bit.

It prints `run-as-administrator flag set: False` on success. Re-running it is
safe.

### Step 5 — use it

Double-click **DeepSeek Harness** on your desktop. A console window opens and
your browser lands on `http://127.0.0.1:3080`.

**Keep that console window open** — closing it stops the server. It is also
where startup errors appear.

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
auto-detects Node and the dsh package at start-up, though it will not create a
desktop shortcut or the icon.

### Manual install (no script at all)

1. Pick a folder, put `DeepSeekHarness.cmd` in it.
2. Right-click it → **Send to → Desktop (create shortcut)**.
3. Right-click the new shortcut → **Properties**:
   * *Target*: the full path to `DeepSeekHarness.cmd`
   * *Start in*: the folder you chose
4. To set the icon: run `install.ps1 -NoShortcut` once to generate
   `deepseek-whale.ico`, then **Properties → Change Icon → Browse** and pick it.

### Uninstall

1. Delete the desktop shortcut.
2. Delete the folder you cloned (and the generated `deepseek-whale.ico` /
   `DeepSeekHarness.local.cmd` inside it).
3. Nothing was written to the registry, and no system setting was changed.

---

## What you get

| File | Purpose |
| --- | --- |
| `install.ps1` | Auto-detects Node + dsh, builds the icon, writes the launcher and the desktop shortcut. |
| `DeepSeekHarness.cmd` | The launcher. Auto-detects Node/dsh; `install.ps1` also bakes in the detected paths. Double-clickable on its own. |
| `assets/deepseek-whale.svg` | Official whale logo, taken from the dsh web frontend bundle. |
| `deepseek-whale.ico` | Generated by `install.ps1` (git-ignored). |
| `DeepSeekHarness.local.cmd` | Generated by `install.ps1` (git-ignored). |
| `legacy/` | The first, machine-specific version of the launcher, kept for reference. See `legacy/README.md`. |

### `install.ps1` options

| Option | Meaning |
| --- | --- |
| `-NodeExe <path>` | Use a specific `node.exe` instead of auto-detecting. |
| `-DshBin <path>` | Use a specific `...\@deepseek-ai\dsh\lib\bin.js`. |
| `-WorkDir <path>` | Working directory recorded in the shortcut. Defaults to this repo folder. |
| `-DesktopDir <path>` | Where to write the shortcut. Defaults to your Desktop. |
| `-ShortcutName <name>` | Shortcut filename without `.lnk`. Defaults to `DeepSeek Harness`. |
| `-NoShortcut` | Build the icon and launcher only. |
| `-WhatIfOnly` | Detect and report; write nothing. |

Handy for testing without touching your desktop:

```powershell
.\install.ps1 -DesktopDir .\out -ShortcutName 'DSH Test'
```

---

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

---

## Design notes (things that will bite you if you edit these files)

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
* To override anything by hand, set `DSH_NODE_EXE`, `DSH_BIN` or `DSH_WORKDIR`
  in the environment rather than editing non-ASCII text into the file.

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

---

## Troubleshooting

**The console window must stay open.** Closing it stops the server. It is also
where startup errors appear, which makes failures far easier to diagnose than a
window that flashes and vanishes.

**Port already in use.** `dsh web` defaults to port `3080`. If a Harness
instance is already running, the new one exits with a bind error. Pass a port
through the launcher:

```
DeepSeekHarness.local.cmd --port 3099
```

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

---

## Security note

The launcher executes `node.exe` against a `bin.js` path inside your npm cache.
That is the same code `npx @deepseek-ai/dsh web` would run — this repo only
changes *how* it is started, not *what* is started. Review `DeepSeekHarness.cmd`
and `install.ps1` before running them; both are short and commented.

Both files are self-contained: no downloads, no telemetry, and no credentials,
tokens, usernames or machine-specific paths. Every path is detected at run time.

---

## License

MIT — see [LICENSE](LICENSE).
