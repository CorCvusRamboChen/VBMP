# UE4SS 转储（gaming PC）

## 已安装的内容（2026-11-04，build 23764881）

- UE4SS：官方 `experimental-latest`，资源 `UE4SS_v3.0.1-1196-g236adf26.zip`
  - 8,756,702 字节，SHA-256 `75dc8b08…a11b`，与 GitHub 给出的一致
  - 稳定版 v3.0.1 是 2024 年的，对 UE 5.4 以上支持不好，所以用这个构建
- 暂存目录：`C:\Users\User\vbmp\tools\UE4SS_v3.0.1-1196-g236adf26\`
- 装进游戏目录 `…\VOIDBREAKER\Binaries\Win64\` 的东西，**只新增了文件，没改任何游戏原文件**：
  - `dwmapi.dll`（代理加载器）
  - `ue4ss\`（UE4SS.dll、配置、Mods）
- 配置改动：`ConsoleEnabled = 1`（启动时弹出黑色日志窗口），`GuiConsoleEnabled = 1`（按 Ctrl+O 打开 GUI 调试窗口和 Live View）
- 自写 mod `VBMPDump`（源码在 `research/ue4ss/VBMPDump/Scripts/main.lua`）：
  - **阶段 1**：游戏启动 90 秒后自动运行
  - **阶段 2**：进入关卡后按 **Ctrl+F9**
  - 每个阶段依次运行：`DumpUSMAP` → `GenerateUHTCompatibleHeaders` → `GenerateSDK` → `DumpAllObjects`
- 脚本在 gaming PC 的 `C:\Users\User\vbmp\scripts\`：`vb_ue4ss_install.ps1`、`vb_ue4ss_collect.ps1`、`vb_ue4ss_uninstall.ps1`

## 你在 gaming PC 前要做的（大约 10 分钟）

1. 正常从 Steam 启动 VOID/BREAKER
2. 会多弹出一个**黑色日志窗口**，这是 UE4SS 在工作，不要关它
   - 第一次启动可能先进"着色器编译"界面，等它结束
3. 停在主菜单，**等日志窗口出现 `[VBMPDump] stage 1 DONE`**
   - 转储期间游戏可能卡住几分钟，正常现象，不要强退
4. 开始一局或进入教学关，在关卡里站着就行
5. 按 **Ctrl+F9**，等日志出现 `[VBMPDump] stage 2 DONE`（同样可能卡几分钟）
6. 正常退出游戏，告诉我一声

之后的事我通过 SSH 处理：运行 `vb_ue4ss_collect.ps1`，把日志、头文件、`.usmap` 拷到 `C:\Users\User\vbmp\dumps\`，然后读取分析。

## 如果出问题

- **游戏启动就崩溃或黑屏**：告诉我，我远程运行卸载脚本。也可以自己在 PowerShell 里运行：
  `powershell -ExecutionPolicy Bypass -File C:\Users\User\vbmp\scripts\vb_ue4ss_uninstall.ps1`
- 崩溃时 UE4SS 会生成 `.dmp` 文件，收集脚本会一起拷走，用来判断是哪一步出的问题
- 如果 Steam 先推送了 1.0 更新：UE4SS 的文件不会被删除，照常启动就行，转储出来的就是 1.0 的数据

## 注意

- 带着 UE4SS 玩时**不要联网打排行榜之类的模式**（游戏目前没有，只是习惯性提醒）
- 转储结果（头文件、`.usmap`、对象列表）都是从游戏推导出来的，**只留在本地分析，不进开源仓库**。仓库里只放我们自己写的代码，以及对类名、函数名的引用
