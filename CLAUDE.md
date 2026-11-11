# VBMP — VOID/BREAKER Multiplayer

为单机 FPS roguelite《VOID/BREAKER》（Stubby Games / Playstack）制作的 2–4 人合作联机 mod，最终在 GitHub 开源。
用户负责测试、决策和验收；Claude 负责调查、设计和实现。

## 当前阶段

见 `docs/status.md`。每次开始工作先读它，结束时更新它。

## 硬规则

1. **不猜游戏 API。** 类名、函数名、参数、偏移只能来自 UE4SS 转储（`research/_local/dumps/`）、UE4SS 日志或资源清单。引用时写明出处。转储里找不到的东西，先转储再写代码。
2. **一次只解决一个可测试的问题。** 每一步都要有明确的验收标准（日志里出现什么、画面上看到什么），不允许一次写出整个联机系统。
3. **记录所有逆向发现。** 写进 `research/phase*-*.md` 或 `docs/`，避免新会话重复调查。
4. **代码绑定游戏版本。** 文档和日志里记下 Steam buildid。游戏更新后，先重跑 `research/scripts/` 里的探测、密钥、清单脚本，再重新做一次 UE4SS 转储，确认接口还在。
5. **每个同步系统都要有明确的权威归属。** 默认房主权威：房主计算敌人 AI、伤害、关卡生成、破坏；客户端只发送意图，并展示结果。
6. **不把游戏的东西放进仓库。** AES 密钥、解包资源、`.usmap`、UE4SS 转储（头文件、对象列表）、资源清单都只留在本地（`research/_local/`、gaming PC 的 `C:\Users\User\vbmp\`）。仓库里只放我们自己的代码和文档，以及对类名、函数名的引用。

## 环境

- **笔记本**（当前工作目录）：写代码、写文档。没有安装游戏。
- **gaming PC** `DESKTOP-CBAJBFJ`，局域网地址 `192.168.1.197`：装着游戏和 UE4SS。
  - 连接方式、注意事项见 Serena 全局记忆 `gaming-pc-desktop-cbajbfj`
  - 登录：`ssh -i ~/.ssh/id_ed25519 user@192.168.1.197`
  - 远端 shell 是 **cmd**。PowerShell 要先 scp 脚本，再用 `powershell -NoProfile -ExecutionPolicy Bypass -File x.ps1` 运行
  - 通过 SSH 启动的 GUI 程序跑在 session 0，看不到画面。需要看画面的测试，由用户在 gaming PC 前操作
- 游戏目录：`C:\D\steamapps\common\VOIDBREAKER`，主程序在 `VOIDBREAKER\Binaries\Win64\`
- UE4SS：装在 `Binaries\Win64\`（`dwmapi.dll` + `ue4ss\`）。日志是 `ue4ss\UE4SS.log`，mod 放在 `ue4ss\Mods\`

## 已确认的游戏事实（build 23764881）

- UE 5.7.4（开发商分支 `ProjectLimaDepot`），Shipping，单体 exe，没有反作弊，没有 SteamStub
- **玩法 100% 是蓝图**，游戏的 C++ 模块只有 UI。玩家 `CH_LimaCharacter_C`，GameMode `GM_LimaGameMode_C`，控制器 `PC_LimaPlayerController_C`
- 资源路径前缀 `/Game/` 对应 `VOIDBREAKER/Content/`
- 详见 `research/phase0-01…03-*.md`

## UE4SS / 游戏的坑（2026-11-04 自测实测）

- **不要用 `LoopAsync` / `ExecuteWithDelay`**：它们在后台线程里执行 Lua，与此同时 hook 在游戏线程里执行同一个 Lua 状态，数据竞争会把值弄乱（数字变成字符串或函数、参数丢失）并导致崩溃。改用游戏线程版本 `LoopInGameThreadWithDelay(ms, fn)`（回调返回 true **不会**停止，要 `CancelDelayedAction(自己的句柄)`；句柄是同一 Lua 状态里共用的小整数，不要按范围取消，2026-11-12 这样把 VBDev 自己的循环也停了）和 `ExecuteInGameThreadWithDelay(ms, fn)`。热键回调里只做 `ExecuteInGameThread(...)`
- **不要用 `ForEachUObject`**：全对象遍历两次让游戏空指针崩溃。只按类名用 `FindAllOf`，或者经已知引用去找
- **不要盲读对象的全部属性**（`ForEachProperty` + `obj[name]`）：本版 UE4SS 不支持某些属性类型（日志：`FObjectPtrProperty`，读出来是 `TrivialObject`），读到就崩
- **不要在蓝图函数 hook 回调（如 `ReceiveTick`）里加载资源、生成 Actor、加组件**：会让游戏线程死锁。放到普通的 `ExecuteInGameThread` 任务里做
- **加载蓝图类要用完整类路径** `LoadAsset("/Game/…/WBP_X.WBP_X_C")`；`LoadAsset(包路径)` 什么都不会加载
- **不要从外部调用 `CH_LimaCharacter_C.RecalculateMods`**：它会卸下全部模组组件而不重新装上，之后再触发 `RecalculateModsEvent` 会崩溃
- 游戏里同时存在多个 `WBP_PlayerInventoryMain_C` 实例（一个预创建的未激活实例），要找 `IsActivated()` 为真的那个
- boss 的过场动画里有 boss 的替身（路径含 `:MovieScene`），按类名找 boss 时要排除
- 复发器是靠"多装几个同样的组件"实现多次触发，不是改 `ExecutionFrequency`
- 蓝图函数的 hook 回调里改结构体参数（`t:get().Translation.Z = …` 或 `t:set({...})`）读回来变了，但没能证实对实际调用生效（2026-11-04 `FireProjectileFromPool`：改了以后玩家仍被打中）。不要靠改参数来"改写"游戏的调用
- `PC_LimaPlayerController_C:FireProjectileFromPool(Transform, 0, nil)` 可以从脚本安全地发一颗敌人子弹，会正常伤害本地玩家（15）
- **原生函数** hook 里改参数**能生效**（2026-11-05：`GameplayStatics:SaveGameToSlot` 的槽名改了以后，游戏真的写到了新文件）；蓝图函数的不行
- 存档：`GI_LimaGameInstance_C.SlotName`（FString，默认 `LimaSaveGame`）决定读写哪个槽；游戏用的异步存档不经过任何可 hook 的 UFunction，只能靠改这个变量拦。客户端存档保护见 `src/lua/VBMP/Scripts/saveguard.lua`
- **换关卡后的旧对象**：`FindFirstOf` 可能返回上一个世界的控制器、菜单控件，而且 `IsValid` 仍为真。本地控制器用 `GameplayStatics.GetPlayerController(GI, 0)`，当前关卡用 `GameplayStatics.GetCurrentLevelName(GI, true)`
- `GameplayStatics.GetRealTimeSeconds(world)` 从当前世界启动开始计时，换关会倒退；需要连续时钟时只累加正的差值
- `RegisterHook` 的后置回调对蓝图函数不触发（2026-11-05 SeePawn 实测：前置 26 次、后置 0 次）。结构体出参（如 `K2_ProjectPointToNavigation` 的 `ProjectedLocation`）不会写回 Lua 表，标量出参可以
- 可以从脚本生成第二个 `CH_LimaCharacter_C`（不附身）当替身，游戏稳定；之后 `FindFirstOf("CH_LimaCharacter_C")` 可能拿到替身，本地玩家要用 `pc().Pawn`。替身不能用 `SetActorHiddenInGame` 隐藏（PawnSensing 跳过隐藏的 Pawn），要隐藏组件
- 敌人开火瞄准写死 `GetPlayerCharacter(0)`；子弹 `BP_EnemyProjectile_Master_C` 在 `ActivateProjectile?` 里记下，下一帧改 `ProjectileMovement.Velocity` 可以改向（父类和 `BP_PRJ_Enemy_Basic_C` 都要 hook）。详见 `research/phase3-05-enemy-aggro.md`
- **不要从脚本强行开火**（`BP_Weapon_Base_C` 的 `FireProjectileEvent`/`Fire_SemiAuto`/`ForceStartShoot`）：2026-11-04 这样做 2 秒后游戏访问违例崩溃。测试伤害用 `GameplayStatics.ApplyPointDamage(目标, 伤害, 方向, {}, PC, 角色, DamageType_Normal_C)`；DamageType 传 nil 不会扣血
- **Steam P2P 从 Lua 用不了**（2026-11-05）：SteamCore 的 `FSteamID` 没有反射字段，经过 UE4SS 变成空表、传回去是 0（自己的 ID、好友、发包对象全是 0）。两台电脑联机由独立的辅助进程 `src/lua/VBMP/steam/vbmp-steam.ps1` 加载游戏的 `steam_api64.dll` 走 Steam P2P，和游戏之间用通道文件（`docs/networking.md`）。它要在用户桌面会话里运行（Steam 在那里），从 ssh 测要用 /IT 计划任务。备用的 TCP 桥接 `tools/dist/vbmp-bridge.ps1`，同机测试用 `tools/remote/bridge_pair.ps1`
- `tools/dev.ps1`、`dualtest-start.ps1` 要在 PowerShell 里直接运行：从 bash 用 `powershell -File … 2>&1` 调用时，ssh 新出现的 post-quantum 警告会被 PowerShell 5.1 当成错误，结果读不到回复、一直超时（2026-11-05）
- **存档对象要等 `GI.MasterSave()` 才更新**：拾取的货币先记在角色和 GI 上，`GI.SaveGameData()` 只是把旧的 `LatestSaveGame` 写盘；要把当前状态写进存档用 `MasterSave()`（2026-11-05）。货币枚举 0 VoidCoins、1 Voidium、2 解密器、3 混沌碎片
- 主菜单 `WBP_PlayMenu_C` 在 CommonUI 栈里，`IsInViewport()` 为假；找它要"优先在视口里的，否则任意有效实例"（`worldsync.lua`、`main.lua` 的 `pressContinue`）
- 蓝图函数的 hook 回调看起来在函数体**执行完之后**才调用：外层函数的记录总在它内部调用的函数之后（2026-11-05 区域推进、据点完成的日志顺序）
- 子类自己声明了同名函数（重写）时，挂在父类上的 hook 不会被调用，要在每个声明它的类上分别 hook（2026-11-05：`BP_Mission_WaveSpawner` 的 `CALL_PlayerOverlappedStart`）
- 队友的替身是 `CH_LimaCharacter_C`，会触发房主世界里所有"玩家走进来"的东西；现在替身关掉了重叠事件（`aggro.lua`）
- **游戏更新后第一次启动要编译着色器**，主菜单可能十几分钟才出来（2026-11-05 build 26439385：约 12 分钟），VBDev 在这期间不响应
- **队友化身**（2026-11-12，`research/phase4-08-avatars.md`）：每个 `CH_LimaCharacter_C` 都会建自己的可见 HUD（`PlayerIcons`、`MissionHUD`），盖在本地 HUD 上，生成的化身 / 替身要折叠它们。武器子 Actor 的 `GetOwner()` 为空，判断"是不是我的枪"要和 `CurrentlyEquipedWeapon` 比地址。注入开火用 `IA_Shoot`（`IA_Fire` 不开枪），hook 每颗子弹用 `BP_Weapon_Base_C:FireProjectile`
- **自测**：`tools/selftest-start.ps1` 启动游戏并点"继续"（从不点"新游戏"），`tools/dev.ps1` 在游戏里执行 Lua 和截图（需要启用 VBDev）。测试前先存档槽，测完恢复。**不要从 ssh 直接运行 `steam.exe`**，游戏要通过 `launch_game.ps1`（一次性计划任务）在用户桌面里启动

## 目录

- `src/lua/VBMP/`：UE4SS Lua mod（原型阶段）
- `tools/`：部署和远程辅助脚本
- `research/`：Phase 0 调查记录和脚本；`research/_local/` 是本地数据，不进仓库
- `docs/`：架构、状态

## 工作流

- 部署 Lua mod：`powershell -File tools/deploy.ps1`（复制到 gaming PC，并在 `mods.txt`/`mods.json` 里启用）
- 看日志：`powershell -File tools/log.ps1`（取 UE4SS.log 末尾和带 `[VBMP]` 的行）
- Lua 输出统一用 `[VBMP]` 前缀，方便在日志里过滤
- 用户测试完以后，先读日志确认，再下结论
