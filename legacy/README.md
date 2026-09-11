# legacy

The **first** version of the fix, kept for reference only.

| File | Notes |
| --- | --- |
| `DeepSeekHarness-launcher.cmd` | The original launcher. Hardcodes the author's `node.exe`, npx cache path and working directory. |

The `.ico` is not duplicated here: `..\install.ps1` regenerates it at the
repository root from `..\assets\deepseek-whale.svg`.

## Why keep it

It documents the root cause in the most direct way possible: the whole fix is
just "call `node.exe` on the installed `bin.js` instead of going through
`npx`". It also shows the environment-variable escape hatch
(`DSH_NODE_EXE` / `DSH_BIN` / `DSH_WORKDIR`).

## Do not use it as-is

The three paths at the top are **from the machine it was written on** and will
not exist on any other machine:

```
D:\NodeJS\node.exe
D:\NodeJS\node_cache\_npx\<hash>\node_modules\@deepseek-ai\dsh\lib\bin.js
D:\NodeJS
```

Use `..\DeepSeekHarness.cmd` (or `..\install.ps1`) instead — both detect Node
and the dsh package at run time. If you do want this file, either edit those
paths or set the environment variables before launching it.

Like every other `.cmd` in this repository, it must stay **pure ASCII**: see the
"Design notes" section of the top-level `README.md` for why `cmd.exe` mangles
batch files that contain non-ASCII bytes.
