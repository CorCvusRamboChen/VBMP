# 状态

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

3.4 的已知缺口（下一步候选）：
- **分仇恨（3.4b）的缺口**：
  - 只验证了步兵的普通子弹
  - 追踪弹（`HomingFast`/`HomingStrong`）会自己转回房主；近战、伤害场、精英的 ProjectileHelper、boss 多半也写死瞄准房主，都没处理
  - 敌人一开始的站位查询仍以房主为中心；现在靠平移 `MoveToLocation` 修正，平移后的点没有投影到导航网格（结构体出参拿不到）
  - 替身关了碰撞：改向的子弹会穿过替身继续飞，在房主画面上打到后面的东西
  - 替身是完整的 `CH_LimaCharacter_C`，游戏逻辑会不会把它当玩家（统计、死亡判定、存档）没有全面检查
  - 选目标规则：最近打它的人（5 s 内，4000 以内）；否则看得见的最近玩家，切换要近一半，且锁定 4 s
- **仇恨**：敌人 AI 只认房主（`AI_Controller_C.LimaCharacter` 是唯一目标，感知组件只看 Pawn，傀儡不是 Pawn）。所以敌人只追房主、只在看得见房主时开火；客户端离得更近时，房主那一发仍然打向房主（压力翻倍）。在 hook 里改 Transform 参数没能证实生效，所以没法把房主那一发改向傀儡。真正的分仇恨需要单独研究（Phase 1c）。**2026-11-05 已调查**：瞄准写死 `GetPlayerCharacter(0)`，移动和焦点跟随黑板 `Target`；子弹可以在下一帧改速度改向。方案见 `research/phase3-05-enemy-aggro.md`（3.4b）。**3.4b 已实现**（`aggro.lua`），剩余缺口见下一条
- 重放子弹按基础伤害 15 结算，敌人自己的倍率（实战 18.75）没带上
- 只覆盖对象池子弹（类型 0）；地面伤害场 `BP_DamageField_C`（`ApplyRadialDamageWithFalloff`，25）、近战、精英的 `ProjectileHelper_*` 还没同步
- 镜像不播开火动画，只有子弹从它的位置飞出

3.3 的已知缺口：客户端的范围伤害（`ApplyRadialDamage*`，爆炸类模组）、近战/冲刺击杀如果不走上面两个函数，还不会转发；命中反馈（受击标记）在镜像上可能不出现；伤害里敌人侧的模组加成按房主的角色计算。

自测方法（3.2）：引擎的 `GameplayStatics.ApplyDamage(敌人, 伤害, PC, 玩家, DamageType_Normal_C)` 走游戏的真实伤害流程（`ReceiveAnyDamage` → `SetHealth`）。**DamageType 传 nil 时不扣血**（`IncomingDamageFromHit` 会记下，但血量不变）。`CH_AI_Base_C.SpawnEnemyImmediate` 需要 1 个参数 `KnowsPlayer?`。

## 设计决定（见 `docs/coop-rules.md`）

1. 时停：全员生效
2. 玩家死亡：倒地，队友可复活
3. 资源产出 ×2；背包共享，装在自己武器上的模组归个人
4. 局外成长：暂定各用各的存档

## 已知外部依赖

- 联机测试需要第二台装了游戏的电脑和第二个 Steam 账号
- 1.0 版本（2026-11-04 发布）更新后，需要重新验证所有接口
