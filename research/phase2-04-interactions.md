# Phase 2 / 04 — 游戏内互动目录

- 日期：2026-11-04，build `23764881`
- 来源：资源清单里全部 `BPI_*` 接口（60 多个）+ CXXHeaderDump 里的实现类和 `CH_LimaCharacter_C` 的函数
- 局限：转储只包含当时**已加载**的类（主菜单和一局 Biome 的中途）。没加载到的类，比如 `BPI_Rail`、`BPI_DroneScan`、`BPI_Glass`、`BPI_UnchartedLift`，只知道接口存在，不知道有哪些实现类。后面换关卡、打 boss、进 Uncharted 时要再转储一次补全

## 1. 互动是怎么组织的

几乎所有互动都走接口，而不是写死在玩家蓝图里。这对同步很有利：**同一类东西走同一组入口**，hook 一次就能覆盖全部。

| 接口 | 作用 | 已知实现类 |
|---|---|---|
| `BPI_Interact` | 通用交互：`InteractObjectQuick(HitPoint, HitComponent)` 短按、`InteractObjectHold` 长按、`PickupInRange`、`LaunchObject/ReleaseObject`、`SetSimulatePhysics` | **42 个**：终端（升级/难度/皮肤/邮件）、商店格子和刷新、宝箱（普通/战利品/Voidium）、拾取物（弹药、血、金币、Voidium、解密器、混沌碎片、武器芯片、遗物、模组、图纸、钩爪升级）、拉杆、门开关、显示器开关、传送器（起点/普通/boss）、电梯、**滑索**、地图连接点、方尖碑、腐化器、回收站、研究所、制造台、触发器 |
| `BPI_Throwable` | 可投掷物：`PickedUpThrowable`、`DropThrowable`、`SetLaunchVector(方向)`、`Primed?(是否瞄准, 目标)`、`IsActorPrimed?`、`GetThrowableInfo(大小, 元素, 名字)`、`HighPriorityItem?` | `BP_PreDestructibleItem_Master_Prop_Throwable`（可投掷道具）、`BP_DST_M_HubVent(_Physics)`（通风口盖板）、`BP_Extraction_DataCube`（任务数据方块）、**`CH_AI_Tick`（一种能被抓起来扔的敌人）** |
| `BPI_ThrowAt` | 可被瞄准的投掷目标 | `CH_AI_Base`（所有敌人）、`BP_Extraction_DataBank`（任务数据库） |
| `BPI_Signal` | 机关信号：`Switch(bool)`、`Activate(bool)`、`InstantSwitchAndLock(bool)` | **47 个**：拉杆、门、激光、灯、发射台、通风地板、boss 舱门、对话和过场触发器、任务逻辑节点、存档点、刷怪器…… 关卡逻辑全靠信号串起来 |
| `BPI_SaveInterface` | 物体自己存/读状态：`GatherSaveData`、`SpawnFromSave`、`RequestSaveActor`、`ShouldSaveThisActor?` | 12 个：各类场景（Scenario）、宝箱/战利品箱/金币箱刷新点、方尖碑和腐化器刷新点、商店刷新点、Uncharted 入口 |
| `BPI_ChestActions` | `SpawnChest`、`SetChestOpened`、`GetChestData`、`SetSpecificMod` | 普通宝箱、战利品箱、稀有战利品箱 |
| `BPI_GrappleInterface` | 钩爪锚点：`GrappleLookAt/StopLookAt` | `BP_GrappleHook` |
| `BPI_RunProgressor` | 推进时关掉本局用过的东西：`DisableRunActor` | 地图连接点、场景、起点传送器、通行阻挡 |
| `BPI_PauseFreeze` | 时停时暂停：`PauseActor/UnpauseActor` | 玩家、敌人、AI 控制器、电梯、滑索 |
| `BPI_DetonationInterface` | 连锁引爆：`DetonateFromNearby` | 已加载的类里没有实现者 |
| `BPI_RewardChallenge` | 奖励挑战 | `BP_RewardChallenge_Master` |

## 2. 玩家这边的动作（`CH_LimaCharacter_C`）

33 个输入动作：移动、视角、跳、蹲、冲刺、冲刺（Dash）、射击、瞄准、换弹、近战、**投掷（IA_Throw）**、**交互（IA_Interact）**、技能（短按/长按）、手雷、治疗、钩爪（长按）、战术动作、切枪（4 把）、切弹种、配件、检视、背包、地图、任务等。

| 类别 | 关键函数 |
|---|---|
| 投掷 / 系绳 | `TraceForThrowables`、`FindNearestThrowable`、`PickUpThrowable`、`ThrowThrowable`、`ThrowViaInteract`、`DropThrowable`、`TraceForEnemyToThrowAt`、`EnemyHitWithThrowable`、`ThrowableHit`；**系绳（Tether 插件）**：`CreateGrappleTether`、`HandleInteractTether`、`EnemyHitTether`、`CallbackHitEnemyTether`、`Melee_CheckPullEnemy`（近战把敌人拉过来） |
| 移动 | 钩爪 `StartGrapple/StopGrapple/PullGrappleTight`；滑铲 `BeginSlide/EndSlide`、冰面 `AdjustSlideIce/EndIceSlide`；跑墙 `BeginWallRun/UpdateWallRun/EndWallRun`；攀爬 `SmallMantle/MediumMantle/LargeMantle`、`GlassMantleTrace`（穿玻璃）；滑索在 `BP_ZipLine`：`LandOnSpline`、`ExitZipline` |
| 交互 | `InteractTrace`、`FireInteract`、长按 `InteractTextBegin/Completed/FailedLongInteract` |
| 能力 | `AbilityFire`、`UsedAbility`、`HandleSelectingBodyAbility`、手雷 `InitiateGrenadeCooldown/ReplenishGrenade`、治疗 `HealFromRestoreBar`、无人机 `DeployedDroneDispatch`、EMP `EMPPlayer`、遗物 `AddRelicToPlayer`、时停 `ABL_ActivateChronoHold?` |

## 3. 同步策略

原则不变：**房主说了算，客户端只发意图**。各类互动按"会不会改变世界"分成四种：

### A. 只影响自己的动作 → 不同步结果，只同步外观
滑铲、跑墙、攀爬、钩爪的移动本身由各自客户端计算，已经包含在 30 Hz 的位置包里。需要额外加一个"动作状态"字段（滑铲中、钩爪中、在滑索上……），让别人那里的傀儡显示对应的姿势或特效。钩爪的绳子可以画成一条从傀儡手到锚点的线。

### B. 改变世界的一次性交互 → 客户端请求，房主执行后广播
开宝箱、拉拉杆、按开关、买东西、刷新商店、激活方尖碑或腐化器、坐传送器或电梯：
1. 客户端那边的 `InteractObjectQuick` 被 hook 拦下（不在本地执行），发送"请求交互：物体 UAID + HitPoint"
2. 房主找到同名物体，调用同一个 `InteractObjectQuick`，游戏原生逻辑跑完（开箱、刷掉落、发信号）
3. 结果按第 2 节和 sync-design 的方式广播：物体状态变化（`SetChestOpened`、信号 `Switch`）、生成的掉落物（NetID）
- 难点：**拦截**。UE4SS 的 hook 不能阻止蓝图函数执行。可行的办法：客户端的交互从输入层截断（hook `FireInteract`，然后用 `CinematicLock` 或在 `InteractEnabled?` 上做文章），这个要实验
- 商店、宝箱掉落属于"谁拿到算谁的"，要和多人的掉落规则一起设计（每人一份？共享？）

### C. 拾取 → 房主仲裁
弹药、血、金币、模组：客户端请求拾取，房主确认没被别人先拿走才生效；掉落物本身是房主生成、带 NetID 的物体。

### D. 投掷物 → 房主模拟物理，客户端看插值
- 抓起：客户端请求"抓起 UAID X"，房主确认后把这个物体标记为"被玩家 P 持有"；持有期间，物体位置跟着 P 的傀儡（房主那边）和 P 自己（P 那边）
- 扔出：发送 `SetLaunchVector` 方向和瞄准目标（`Primed?` 的目标）；房主那边执行真正的投掷，物理飞行由房主模拟，以 20 Hz 广播位置，客户端插值；命中（`PrimeHit`）造成的伤害和破坏由房主计算，并按破坏同步的方式广播
- **`CH_AI_Tick` 是一种可以被扔的敌人**：它同时是敌人（房主权威）和投掷物，要单独处理
- 系绳拉敌人（`Melee_CheckPullEnemy`、`EnemyHitTether`）：敌人的位置本来就由房主说了算，客户端只发"我对敌人 E 用了系绳"，房主执行

### E. 关卡信号和存档型物体 → 状态同步 + 中途加入
- `BPI_Signal` 的 47 种物体：房主广播"UAID X 的信号变成了 on/off/锁定"，客户端调用同一个 `InstantSwitchAndLock` 或 `Switch`
- `BPI_SaveInterface`：游戏已经能把这些物体序列化成 `FSTR_SaveObjectDetails`（位置、类型、宝箱/商店/方尖碑/腐化器/场景信息、是否完成）。**中途加入时可以直接复用**：房主 `GatherSaveData`，客户端 `SpawnFromSave`

### F. 全局效果 → 需要设计决定
时停（`BPI_PauseFreeze`、`ABL_ActivateChronoHold?`）、EMP、慢动作：见 `docs/status.md` 设计问题 1。

## 4. 还不清楚的地方

1. 客户端怎样**不执行**本地交互，只发请求（第 3B 节）
2. 投掷物被持有时，是什么在驱动它的位置：附着到玩家的 `ThrowableLocation` 组件，还是每帧设置？决定房主那边怎么让它跟着傀儡
3. 没加载到的接口实现类（滑轨 Rail、无人机扫描、玻璃、Uncharted 电梯）
4. 多人的掉落和商店规则（设计问题，不是技术问题）

VBTrace 探针已经加上了第 2、3 节里的关键入口（投掷、系绳、钩爪、跑墙、滑铲、各类交互、开箱、滑索、拉杆和信号）。下次统一测试时，正常玩一会儿就能得到这些互动的真实调用顺序和参数，用来回答问题 1 和 2。
