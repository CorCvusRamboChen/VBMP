# 状态

## 当前进度（2026-11-05 早上）

- **安装包**：`dist/VBMP-0.5.3.zip`（`tools/package.ps1 -Version 0.5.3`）；联机默认走 Steam P2P 辅助进程（`docs/networking.md`），TCP 桥接是备用；协议版本 `MOD_BUILD = 2`，和旧版本互相拒绝连接
- **2026-11-05 下午自查**：
  - **Steam P2P 从 Lua 根本连不上**（`FSteamID` 经过 UE4SS 变成 0，见 `docs/networking.md`）。之前所有双开测试走的都是本机文件通道，所以没发现
  - 先做了"文件通道 + TCP 桥接"（0.3.1），随后改成 Steam P2P 辅助进程（0.4.0）：独立进程加载游戏的 steam_api64.dll，用真正的 SteamID；开房 / 加入时自动启动。单账号自测通过（初始化、rich presence、给自己发包、和游戏共存、随联机 / 游戏退出）；两个账号之间的连接待和朋友实测
  - 游戏更新到 build 26439385（2026-11-05 10:34 换了资源包），已在新版本上重测
  - 新版本 + 桥接双开实测（20:16，同一台 gaming PC，两个桥接经 127.0.0.1 TCP）：B 加入 → 收到 200 KB 存档、读进 A 的世界；延迟 50–95 ms；所有 hook 注册成功；步兵锁定 B 的替身，28 发子弹转发、B 重放 27 发，110→0 后倒地
  - 没测：真正跨两台电脑（防火墙：笔记本连 gaming PC 的 27777 被挡，房主必须先运行 `firewall-allow.bat`）、互联网延迟和丢包
- **全部模块一起的回归测试（双实例，05:59）**：
  - 连接正常
  - 敌人锁定 B 的替身，24 发子弹转发并重放（每发 18.75），20 发房主子弹改向
  - 破坏同步正常；两个进程都没崩
- **已做完并自测**：3.1–3.9、3.6 存档保护、3.7 世界同步（含 3.7b/3.7c）、3.8 伤害转发、4.1/4.1b 倒地复活、4.2 时停、4.3 掉落每人一份、4.4 交互
- **已决定（2026-11-05）**：背包个人所有，不做共享背包
- **0.8.3**：房主离开（主动离开或 45 秒超时）后，客户端自动结束联机，回主菜单即回到自己的存档并带回局外收获
- **0.8.2**：联机时全局慢动作固定为 1（`coopfixes.lua`）；核对：敌人优化器实测不降频；傀儡流送源没问题（之前掉下去是通行地形不同）。`docs/coop-issues.md` 的严重项都处理完了，剩下 boss 竞技场要等实际打到 boss 时看
- **0.8.1**：朋友单独去了别的关卡会被拉回房主的关卡（10 秒，刚加入或刚换关后 90 秒内不拉）；核对加密宝箱、传送器解锁是个人操作，不同步；boss 竞技场的开始 / 过场要等实际打到 boss 时观察
- **0.8.0**：替身不再触发房主世界里的东西（`aggro.lua`）；据点 / 竞技场：房主完成 → 客户端完成（收护盾、给自己的奖励），客户端先进入 → 房主开始（`mission.lua`，`MISSION` 30）。调查记录 `research/phase4-07-strongholds.md`
- **0.7.0**：系统排查"单人假设在联机下出错"的地方，清单在 `docs/coop-issues.md`（证据来自对象转储的 `CallFunc_*` / `BndEvt_*` 和实测）。这一版修了：联机时不暂停（`coopfixes.lua`）；谁先进入新区域其他人被传送过去（`regionsync.lua`，`REGION` 28）；区域间通行地形统一成房主的（`traversal.lua`，`TRAV` 29，原来每个进程随机挑，6 段里 5 段不同）；客户端那边的房主傀儡也带流送源。调查记录 `research/phase4-06-regions.md`
- **0.6.0**：剧情同步（`storysync.lua`，消息 `STORY` 27，`MOD_BUILD` 3）。剧情 / 对话都放在"序列容器"里（`BP_SequenceContainer`、`_NormalUse`、`_Dialogue`、`_RandomTable`、`BP_TriggerDialogueSequence`），由触发链 `BP_PlayerTrigger` → `BP_SignalOps_DoOnce` → 容器 `Switch(true)` 开始播放；任何人的容器跑 `Switch`/`Activate` 时，其他人对同一位置的同类容器调用同一函数（30 秒内同一个不重复）。自测：脚本调用容器 `Switch(true)` 播放了 `LS_0500_Entrance`（语音、字幕）；双开 A 触发 → B 3 ms 后播放同一段，B 触发 `LS_0500_Address` → A 40 ms 后播放（IDRIS 台词 + 过场特效）；编解码自检 26/26。没测：真实走进触发器（脚本移动角色没触发重叠）、boss 入场过场（没同步）、锁定角色的长过场
- **0.5.3**：敌人联机加强（`enemies.lua`，规则见 `coop-rules.md`）：2 人血量 ×1.5、数量 ×1.5。双开自测：A 刷 6 个步兵 → 额外生成 4 个，A、B 都是 10 个，血量 39→58、101→151、70→105，B 的镜像血量与 A 一致。没测：波次 / 据点任务的击杀计数、额外敌人从生成点出现的样子（没有出生特效）
- **0.5.2**：带回列表补上解密器和图纸（`Decryptors`、`InventorySchematics`、`FoundWorldSchematics`）。依据：游戏背包页标注虚空素、解密器、混乱碎片"死亡后保留"，信用币"死亡后删除"，图纸"死亡后仍会保留"（截图 2026-11-05）。混乱碎片 = "完成混乱任务获得的稀有货币奖励"，每幕最多 2 个（`WBP_ChaosMissionRow`），由宝箱生成（`BP_ItemChest_Master.SpawnChaosFragment`），转储里没有 boss 引用它
- **0.5.1**：背包里的 VBTools 面板可以 [收起]/[展开] 和 [-]/[+] 缩放（0.5–1.3，以顶边中点为轴），记在 `Saved\VBTools_panel.txt`。修复：游戏更新后武器插槽数组读出来是 `TrivialObject`，"找三连"抛错让整块面板被禁用；现在读不出就当 0，各部分单独保护。自测截图：默认大小正常；收起 + 0.7 只剩标题栏
- **0.5.0（2026-11-05 晚）**：
  - 主菜单联机面板（`menu.lua`）：[继续并开房]、开房中的 Steam 好友列表（辅助进程 `-Role list`）+ [加入]、[自动加入好友]、存档备份列表 + [恢复]（两次点击确认）、上次带回结果。自测：中文字体 `FNT_RevxNeue` 正常；继续并开房 → 进世界后 Steam 开房；双开里 B 停在主菜单加入 → 4 秒进入 A 的世界。真实鼠标点击没测（测试走同一代码路径的命令 `menuhost`/`restore1`）
  - 局外成长带回（用户选定只带回局外）：`saveguard.lua` 在回到主菜单时把联机存档的局外属性拼回真实存档，先备份。自测：联机中拾取 Voidium +13、VoidCoins +16 → 回主菜单后真实存档 Voidium 336→349、VoidCoins 仍 759；内存里的存档也重新读了
  - 发现：拾取的货币先在角色和 GI 上，游戏的 `GI.MasterSave()` 才写进存档对象；`SaveGameData` 只写旧对象。混沌碎片两种方式都没进存档文件
  - 备份（`backups.lua`）：开房 / 加入 / 带回 / 恢复前各备份一次，索引 `Saved\VBMP_backups.txt`，保留 20 份。自测恢复：文件和内存都回到备份值
  - 货币枚举 `Enum_PickupOrbType`：0 VoidCoins、1 Voidium、2 解密器、3 混沌碎片（`AddCurrency` 实测）
- **等真实游戏验证**（脚本测不到）：
  - 真实按键 E 复活
  - 关卡里真实的拉杆、门开关、方尖碑
  - 近战伤害转发
  - 追踪弹
  - 精英 helper 弹幕、boss 攻击
  - 弹药、血包、模组掉落
  - 两台电脑、两个 Steam 账号联机（Steam P2P）


## Phase 0 — 调查（✅ 2026-11-04 完成）

结论：可行。见 `research/phase0-03-reflection-dump.md`。

## Phase 1 — MOD 加载与远端玩家傀儡

| 步骤 | 目标 | 验收 | 状态 |
|---|---|---|---|
| 1a | Lua mod 生成"幽灵傀儡"：记录本地玩家的位置，延迟 2 秒在傀儡身上回放 | 游戏里能看到一个小白人沿着自己 2 秒前的路线移动；日志里每 5 秒有一条位置记录 | ✅ 2026-11-04 生成和跟随都通过（小白人 SKM_Quinn_Simple）。v1 用 33 ms 计时器，约 28 Hz，画面卡顿；v2 改为挂 `PC_LimaPlayerController_C:ReceiveTick` 逐帧更新，并按时间戳插值，🔧 等待测试 |
| 1b | 换图、死亡、回菜单后傀儡能自动重建，不崩溃 | 跨关卡跑一局，日志里没有错误 | ⏳ |
| 1c | 傀儡能被敌人感知、远离房主时周围关卡仍加载（WP 流送源 + 导航） | 仇恨已调查（2026-11-05，`research/phase3-05-enemy-aggro.md`）：可行，方案是房主端替身 `CH_LimaCharacter_C`；关卡流送未查 | ⏳ |
| 1d | 搭好 C++ mod 工程（UE4SS C++ 模板），把 1a 移植过去，接入 UDP | 两个进程之间（先同机回环）傀儡跟随 | ⏳ |

> 2026-11-04：联机暂停，先做单机工具 `VBTools`（`src/lua/VBTools/`）。VBMP 幽灵傀儡已部署但被禁用（`deploy.ps1 -Enable VBMP` 可恢复），1a 还没测试。

## 单机工具 VBTools

| 功能 | 状态 | 说明 |
|---|---|---|
| 存档备份 | ✅ | `tools/remote/save_backup.ps1`；2026-11-04 05:25 已备份到 gaming PC 的 `vbmp\save-backups\before-boss-fix-*` |
| boss 卡阶段救援 | 🔧 已部署，等待测试 | Ctrl+F1 查看状态，F2 解除卡死，F3 推进阶段，F4 正常击杀，F5 让场地判定胜利 |
| 存档槽（保存当前进度，去打困难模式，以后再切回来） | 🔧 v1 已部署 | gaming PC 上双击 `vbmp\VBSaves.bat`。整个文件快照，已存槽 `boss-before-fix` |
| 局内升级局外属性 | 🔧 已部署，等待测试 | 面板按钮 [永久升级]/[研究所]：`PL_GameStatics.GetRootWidget(PC).PushWidgetToMenuStack(WBP_PermaUpgrades_02 / WBP_Researcher_Main)`，和终端打开方式相同。`Vitality…Exponent` 六项属性只出现在存档里，没有找到使用它们的界面，可能是废弃字段 |
| 事件探针 + 破坏回放（VBTrace） | 🔧 已部署，等待测试 | 见 `docs/sync-design.md` 第 5 节 |

**统一测试**：`docs/test-plan.md`（T1–T15）。测完后在笔记本上运行 `powershell -File tools/collect-test.ps1` 收集结果。三个 mod 的日志会跨重启写进 `%LOCALAPPDATA%\VOIDBREAKER\Saved\VB_mods.log`。
| 3 个相同模组 → 1 个触发两次 | 🔧 v1 已部署，等待测试 | Ctrl+F6 合成，Ctrl+F7 查看；原理见 `research/vbtools-01-difficulty-mods.md` |
| 局内 UI 面板 | 🔧 原型已部署，等待测试 | `src/lua/VBTools/Scripts/ui.lua`：打开背包时在右侧注入面板（合成列表、boss 救援、存档快照），Ctrl+F8 开关。运行时用 UMG 控件拼出来，按钮靠轮询检测点击。真正的"拖进格子合成"需要 UE 5.7 编辑器做蓝图 mod，暂不做 |

热键分配：VBTools 占 Ctrl+F1–F8，VBMP 幽灵傀儡开关改为 Ctrl+F10（两个 mod 同时启用）。

## 2026-11-04 自测结果（远程控制台 VBDev，存档测完已恢复）

| 项 | 结果 |
|---|---|
| 四个 mod 加载、VBMP 编解码自检 8/8 | ✅ |
| 本机回环：编码→发送→接收→解码→傀儡 | ✅（修复了"在 tick hook 里生成傀儡导致死锁"之后）；傀儡坐标和玩家完全一致，顺滑度待用户目测 |
| 背包面板显示 | ✅（修复了"盯住未激活的背包实例"之后）；⚠ 面板盖住了右侧物品栏，要挪位置 |
| 局内打开永久升级 | ✅（修复了类加载路径之后）；购买待用户点击验证 |
| boss 状态查询 | ✅；修复：排除过场动画里的 boss 替身 |
| 三连检测 | ✅ |
| **模组合成** | ❌ **已禁用**：外部调用 `RecalculateMods` 会卸掉全部模组，再重算会崩溃；复发器的原理也和假设不同。需要重新设计 |
| 破坏录制/回放 | 控制链路 ✅；实际破坏的录制和回放待用户打东西时验证 |
| Steam P2P 自发自收 | ⏳ 没来得及测 |

### UI 接入自测（2026-11-04 第二轮）

- `hud.lua`（UI 会话产出）已接入：新消息 `PLAYER_HP`/`CURSOR`/`DRAG_ITEM`（编解码自检 11/11），队友行、状态角标、加入/离开通知、背包队友鼠标
- 回环实测 ✅：队友行显示"Loopback 110/110"+ 血条，右上角"VBMP 本机回环 · 2 人"，背包里出现队友光标和名字
- 修复：HUD 背包层也盯住了未激活实例；`player.Health` 在 VBMP 的 Lua 环境里读成函数（改用 `GetPlayerHealth` 输出参数 + 类型检查）；`table.concat` 尾调用报错（改为手动拼接）
- 未验证：倒地/复活提示（等倒地机制）、敌人血条（数据同步已通过 3.2，画面待目测）、拖拽高亮（需要真的拖东西）、名字牌在画面里的位置
- `hud.frame()` 暂不在 tick hook 里调用（会创建控件，有死锁风险），名字牌按 20 Hz 更新

### 双实例联机（2026-11-04 第三轮）✅ Phase 2 验收通过

- 同一台 gaming PC 上同时运行两个游戏进程：A 由 Steam 启动，B 通过 `tools/remote/launch_second.ps1` 启动（在 exe 旁放 `steam_appid.txt` 绕过 Steam 启动器，窗口模式 1280×720；`-Cleanup` 删除）
- 进程身份：`instance.lua`（按 GI 对象地址在 `VBMP_slots.txt` 里认领 A/B）；命令/状态/远程控制台文件按身份分开（`VBMP_cmd_B.txt`、`VBDev_cmd_B.lua`、`dev.ps1 -Slot B`）
- 传输 `localfile`（`transport.lua`）：A2B/B2A 两个只追加的帧文件；命令 `lanhost` / `lanjoin`
- 实测：B 连上 A；双方各生成对方的傀儡（房主那边加了流送源和导航生成器）；包往返约 250/250，延迟 20–33 ms；A 的画面里能看到 B 的小白人、HUD 名字牌、队友血条和延迟
- **根因修复**：所有 `LoopAsync`/`ExecuteWithDelay` 改为游戏线程版本（`LoopInGameThreadWithDelay` 等）。之前各种"值变成字符串/函数"的怪错误和随机崩溃，都是后台线程与游戏线程同时操作同一个 Lua 状态造成的

## Phase 2 — 基础联机（玩家互相看到移动）

| 步骤 | 内容 | 状态 |
|---|---|---|
| 2a | 传输层：纯 Lua，通过游戏自带的 SteamCore 走 Steam P2P（`docs/networking.md`） | 🔧 已写，未测 |
| 2b | 会话：房主 / 客户端 / 本机回环；用 Steam 好友富状态自动发现房间；握手、心跳、超时 | 🔧 已写，未测 |
| 2c | 远端玩家傀儡：插值、名字牌、关卡不同时隐藏；房主那边加流送源和导航生成器 | 🔧 已写，未测 |
| 2d | VBTools 面板"联机"区 + 热键 Ctrl+Shift+H/J/L/G | 🔧 已写，未测 |
| 2e | 第二台电脑的安装包 `tools/package.ps1` → `dist/VBMP-0.2.0.zip` | ✅ 已生成 |
| — | 原来的幽灵傀儡（1a）并入"本机回环"模式，Ctrl+F10 已取消 | |

**测试检查点**：`docs/test-plan.md` 的 M1–M6，需要第二台装了游戏的电脑和第二个 Steam 账号（两个账号互为好友）。

## Phase 3 — 敌人、战斗、破坏同步（房主权威）

代码：`src/lua/VBMP/Scripts/enemies.lua`。消息：`ENEMY_SPAWN` 12、`ENEMY_STATE` 13（位置、朝向、血量、最大血量，20 Hz）、`ENEMY_DESPAWN` 14、`ENEMY_DEATH` 15。

| 步骤 | 内容 | 验收 | 状态 |
|---|---|---|---|
| 3.1 | 敌人出生镜像：房主 hook `GM_LimaGameMode_C:AddEnemyPool` 分配 NetID；客户端生成同类镜像，每帧拆掉 AI 控制器，按插值位置移动；客户端自己刷出的敌人删掉 | 双实例：A 刷 `CH_AI_Grunt_C`，B 出现镜像，坐标一致 | ✅ 2026-11-04 |
| 3.2 | 血量和死亡：房主用 `GetHealth` 读血量随状态包发送；客户端写入镜像并用 `hud.applyEnemyHealth` 刷新血条（镜像血量最低保持 1，不会自己死）；房主血量 ≤ 0 时可靠广播死亡，客户端调用 `DeathEvent(true)`（不掉落） | 双实例：A 扣血 39.3→24.3，B 1 秒内同步；A 击杀后 B 40 ms 内播放死亡，尸体消失后镜像移除 | ✅ 2026-11-04 16:26 |
| 3.3 | 客户端命中意图：客户端 hook `GameplayStatics.ApplyPointDamage`/`ApplyDamage`，目标是镜像时发 `ENEMY_HIT`（NetID、伤害、伤害类型类路径、方向、骨骼）；房主用同样的 `ApplyPointDamage` 走游戏自己的伤害流程。镜像 `bCanBeDamaged = false`：引擎直接忽略本地伤害（不扣血、不死、不掉落），而 hook 在调用前就已拿到命中 | 双实例：B 打镜像 15 → B 本地血量不变，A 70→55，B 镜像同步为 55；B 用真实武器开火（57.6 伤害）→ A 击杀 → B 21 ms 后播死亡 | ✅ 2026-11-04 23:17（打尸体不再发意图的修复未重测） |
| 3.4 | 敌人子弹打客户端：房主 hook `PC_LimaPlayerController_C:FireProjectileFromPool(Transform, 类型, 敌人的 AI_Controller)`，按控制器的 Pawn 查 NetID；离枪口最近的玩家如果是客户端，就只发给它 `ENEMY_SHOT`（枪口位置 + 相对"正对目标"的俯仰/偏航偏差 + 子弹类型）；客户端用自己的 `FireProjectileFromPool(…, nil)` 朝自己的玩家重放，伤害走客户端自己的 `DealDamageToPlayer` | 双实例：grunt 离 B 400、离 A 1600 → A 转发 18 发、B 重放 18 发，偏差 0.0°/-0.4°，B 被打中 4 次（110→50） | ✅ 2026-11-04 23:32 |
| 3.4b | 分仇恨：房主替身 + 改目标 + 房主子弹改飞替身 + 按指定目标转发子弹（`aggro.lua`，设计见 `research/phase3-05-enemy-aggro.md`） | 双实例：步兵锁定 B 的替身，20 s 内跟在替身 300–900 范围内；24 发全部转发给 B 并重放（B 110→35），房主 0 次被打，20 发房主子弹改向；房主打它一下就切回房主；B 离开后替身删除、敌人还给房主，没有崩溃 | ✅ 2026-11-05 02:49 |
| 3.5 | 破坏同步："物体碎了"事件（actor 名含 UAID + 坐标），双向，房主转发，中途加入补发（`destruction.lua`，`research/phase3-06-destruction.md`） | 双实例：A 打碎地砖/玻璃 → B 同步碎掉；B 打碎地砖 → A 碎掉；没有回声；B 中途加入后补上 A 之前打碎的两块 | ✅ 2026-11-05 04:07 |
| 3.6 | 客户端存档保护：联机当客户端时把 `GI.SlotName` 换成 `VBMP_client`（先复制真实存档过去），同步存档和删档的原生 hook 作为第二层；离开后保持到回主菜单再换回（`saveguard.lua`） | 单实例：客户端身份下同步+异步存档都写进 `VBMP_client.sav`，`LimaSaveGame.sav` 时间戳不变；回主菜单后 2 秒内换回，继续游戏后存档正常写回真实存档 | ✅ 2026-11-05 04:22 |
| 3.7 | 世界同步 v1：客户端加入时房主存档并分块发送（`WORLD_SAVE` 19），客户端写入 `VBMP_client.sav`、回主菜单按继续读进房主的世界（`worldsync.lua`，`research/phase3-07-worldsync.md`）；顺带修了会话时钟随换关倒退、旧控制器被当成本地玩家 | 双实例：B 先在 Biome_04，加入后 5 秒内进入 A 的 Biome_05，物体名字坐标一致，联机不掉线，破坏同步照常 | ✅ 2026-11-05 04:37（角色状态的缺口已由 3.7c 修复） |
| 3.7b | 房主换关后客户端跟随：房主的关卡名从一个关卡变成另一个，3 秒后重发存档，客户端按更新的传输编号重新读档；任何包都刷新对端存活时间，超时 10→45 秒（读关卡时游戏线程会停很久） | 双实例：A 回主菜单再读另一个存档进 Biome_04，B 4 秒内跟进 Biome_04，全程不掉线 | ✅ 2026-11-05 04:47 |
| 3.7c | 客户端保留自己的角色：只把房主存档里 63 个布局类顶层属性（关卡、生物群系、层级、起点、破坏/开关记录、难度等）拼进客户端自己的存档，其他（武器、模组、背包、货币、升级）保持客户端的；按 GVAS 顶层属性整段替换（`gvas.lua`） | 双实例：B 用另一个存档（VoidCoins 0）加入 A（759）→ B 进入 A 的 Biome_05 第 4 层 B05_18，VoidCoins 仍为 0；拼接 53+26 个属性 | ✅ 2026-11-05 04:58 |
| 3.8 | 伤害转发（`damagesync.lua`，消息 `DST_HIT` 20、`RADIAL` 21）：客户端对可破坏物的点伤害发给房主累加；客户端本地玩家的范围伤害（爆炸）在房主那边同位置重放（打真敌人和可破坏物，重放时房主玩家临时免伤）；敌人的范围伤害（地面伤害场）转发给范围内的客户端在本地重放（只伤到客户端自己的玩家）。追踪弹：房主端改向时关掉追踪（`SetHomingNone` + `bIsHomingProjectile`），未用真实追踪弹敌人验证 | 双实例：B 打地砖 300 + A 打 300 → 两边都碎；B 在镜像处爆炸 40 → 房主步兵 70→30；A 在 B 替身处放敌人伤害场 → B 扣 25；B 被重放子弹每发 18.75（与房主一致：倍率在受击方，按难度，3.7c 同步难度后自然一致） | ✅ 2026-11-05 05:15 |
| 3.9 | 敌人的非子弹攻击：近战（实测 `CH_AI_Hound` 近战是直接调用 `CH_LimaCharacter_C.DealDamageToPlayer(20)`，不经过引擎伤害函数）打在替身上时，房主转发给对应客户端（`PLAYER_HIT` 26），客户端对自己调用同一个函数；替身改为保留碰撞（近战靠碰撞找目标）、打开 `Debug_GodMode`；不主动发现替身的敌人（Hound 停在 300 外、`EnemyState` 0）在分给队友且看得见时调用 `AI_Controller_C.ForceSeePlayer()` 进入战斗 | 双实例：Hound 生成在 B 的替身旁 → 自己进入战斗（状态 2、看得见），远程攻击转发给 B，B 被打 8 次 15 后倒地。**近战转发没观察到**：这个距离 Hound 一直用远程；精英的 `ProjectileHelper`、boss 攻击没处理 | 🔧 2026-11-05 05:57 |

3.4 的已知缺口（下一步候选）：
- **分仇恨（3.4b）的缺口**：
  - 只验证了步兵的普通子弹
  - 追踪弹（`HomingFast`/`HomingStrong`）会自己转回房主；近战、伤害场、精英的 ProjectileHelper、boss 多半也写死瞄准房主，都没处理
  - 敌人一开始的站位查询仍以房主为中心；现在靠平移 `MoveToLocation` 修正，平移后的点没有投影到导航网格（结构体出参拿不到）
  - 替身关了碰撞：改向的子弹会穿过替身继续飞，在房主画面上打到后面的东西
  - 替身是完整的 `CH_LimaCharacter_C`，游戏逻辑会不会把它当玩家（统计、死亡判定、存档）没有全面检查
  - 选目标规则：最近打它的人（5 s 内，4000 以内）；否则看得见的最近玩家，切换要近一半，且锁定 4 s
- **仇恨**：敌人 AI 只认房主（`AI_Controller_C.LimaCharacter` 是唯一目标，感知组件只看 Pawn，傀儡不是 Pawn）。所以敌人只追房主、只在看得见房主时开火；客户端离得更近时，房主那一发仍然打向房主（压力翻倍）。在 hook 里改 Transform 参数没能证实生效，所以没法把房主那一发改向傀儡。真正的分仇恨需要单独研究（Phase 1c）。**2026-11-05 已调查**：瞄准写死 `GetPlayerCharacter(0)`，移动和焦点跟随黑板 `Target`；子弹可以在下一帧改速度改向。方案见 `research/phase3-05-enemy-aggro.md`（3.4b）。**3.4b 已实现**（`aggro.lua`），剩余缺口见下一条
- （已解决）重放子弹的伤害：实测倍率 ×1.25 在受击方（无发起者的子弹 BaseDamage 18.75 → 实际 23.4375），世界同步带上难度后客户端每发 18.75，与房主一致
- 地面伤害场已由 3.8 转发；对象池子弹类型 1–10 都走同一条路（类型→类：1 Twizzler、2 Bar、3 Bar_FIR、4 Basic_Fire、5 HomingFast、6 HomingStrong、7 Basic_Ice、8/9 Slow、10 Basic_Electric）；近战、精英的 `ProjectileHelper_*` 还没同步
- 镜像不播开火动画，只有子弹从它的位置飞出

3.3 的已知缺口：客户端的范围伤害（`ApplyRadialDamage*`，爆炸类模组）、近战/冲刺击杀如果不走上面两个函数，还不会转发；命中反馈（受击标记）在镜像上可能不出现；伤害里敌人侧的模组加成按房主的角色计算。

自测方法（3.2）：引擎的 `GameplayStatics.ApplyDamage(敌人, 伤害, PC, 玩家, DamageType_Normal_C)` 走游戏的真实伤害流程（`ReceiveAnyDamage` → `SetHealth`）。**DamageType 传 nil 时不扣血**（`IncomingDamageFromHit` 会记下，但血量不变）。`CH_AI_Base_C.SpawnEnemyImmediate` 需要 1 个参数 `KnowsPlayer?`。

## Phase 4 — 合作规则

| 步骤 | 内容 | 验收 | 状态 |
|---|---|---|---|
| 4.1 | 倒地 + 复活（`downed.lua`，消息 `REVIVE` 22，`PLAYER_HP` 的倒地位）：有队友在线时，致命一击在 `DealDamageToPlayer` 前置 hook 里打开 `Debug_GodMode`（实测它、`DEBUG_TempGodMode?`、`bCanBeDamaged=false` 都能挡伤害）；倒地后移动 150、可开枪，45 秒流血；队友在 250 以内站 3 秒即复活（回 30% 血）；超时或队友全走则关无敌并施加致命伤害，走游戏自己的死亡流程 | 双实例：B 吃 200 伤害 → 倒地（画面"你倒地了/等待队友复活"，无死亡画面，血量显示 0）；A 走到旁边 3 秒后 B 复活 33/110、速度恢复 800；第二次倒地无人救 → 45 秒后死亡并在同一世界重生，联机不断，存档仍写 `VBMP_client` | ✅ 2026-11-05 05:18 |
| 4.2 | 时停全员生效（`timestop.lua`，消息 `TIMESTOP` 23）：hook `PC_LimaPlayerController_C.ABL_ActivateChronoHold?`（实测它调用 `FreezeTime`+`FreezeBH`，duration 秒后 `ResumeTime`+`ResumeBH`，全局时间流速不变）；本地激活发给房主，房主应用（冻住真敌人）并转发给其他客户端 | 双实例：B 用 3 秒时停 → A 上的步兵坐标在 3.6–6.1 s 不动，之后继续移动 | ✅ 2026-11-05 05:22 |
| 4.3 | 掉落每人一份：客户端镜像敌人死亡改为 `DeathEvent(false)`（允许掉落），每个玩家在自己的世界里拿到自己的掉落（`enemies.lua` 的 `DROPS_ON_CLIENTS`） | 双实例：A 打死步兵 → A 的 VoidCoins 759→762，B 自己的镜像掉落也让 B 759→762（币自动飞向玩家） | ✅ 2026-11-05 05:29（弹药/血包/模组掉落没单独验证；脚本生成的敌人掉落很少） |
| 4.1b | 倒地规则对齐 `coop-rules.md`：按住交互键（`IsInputKeyDown` 查 E / 手柄 X）在 250 以内 3 秒才复活，靠近但没按键时显示提示；去掉个人流血倒计时；房主看到全员倒地时发 `WIPE`（24），所有人走游戏自己的死亡流程；身边没有队友时直接死亡 | 双实例：A 站在倒地的 B 旁 6 秒不按键 → 不复活；按住（测试命令 `revivehold` 模拟）→ B 复活 33/110；B、A 先后倒地 → 两边同一秒"whole team down"并死亡 | ✅ 2026-11-05 05:38（真实按键未测：我没法在测试里按键） |
| 4.4 | 交互同步（`interact.lua`，消息 `INTERACT` 25）：本地玩家对宝箱（`BP_ItemChest_Master`、`BP_Voidium_ItemChest`、`BP_LootChest_Master` 及其不覆盖的子类）、开关（`BP_Monitor_Switch(_Zone)`、`BP_DigiDoor_Switch`、`BP_SwitchAct(_01)`）、拉杆（`BP_PuzzleLever`）、方尖碑的 `InteractObjectQuick/Hold`，在其他人那份"同类 + 坐标取整 50"的物体上重放；宝箱各自开、各自掉落（每人一份）。不重放：拾取物、终端、商店、制造台、回收站、研究所、腐化器（个人效果）、传送器、电梯、地图连接点、滑索 | 双实例：两边同坐标生成的宝箱，A 打开 → B 的 `ChestOpened?` 也变 true；B 拉拉杆 → A 收到并重放（脚本生成的拉杆两边都不响应，`On?` 不变，关卡里的真拉杆待实际验证） | ✅ 2026-11-05 05:44 |

已知：倒地那一下的扣血没挡住（血量会到 0，但不会死）。

## 设计决定（见 `docs/coop-rules.md`）

1. 时停：全员生效
2. 玩家死亡：倒地，队友可复活
3. 掉落每人一份；背包和武器模组都归个人
4. 局外成长：暂定各用各的存档

## 已知外部依赖

- 联机测试需要第二台装了游戏的电脑和第二个 Steam 账号
- 1.0 版本（2026-11-04 发布）更新后，需要重新验证所有接口
