# Phase 3 调查：敌人仇恨（让敌人追打队友）

build 23764881，2026-11-05 单实例自测（Biome_05，测试用 `CH_AI_Grunt_C`）。测试脚本只在本地 scratchpad，结论都在这里。

## 结论（一句话）

可行，但要在房主端为每个远端玩家放一个**替身 `CH_LimaCharacter_C`**，再做三件事：持续改写敌人的目标引用、放开感知限制、把房主那颗子弹改飞向替身。敌人开火的瞄准是写死的 `GetPlayerCharacter(0)`，没法从字段上改。

## 敌人怎么找目标

出处：CXX 转储 `AI_Controller.hpp`、`CH_AI_Base.hpp`、`AIModule.hpp`，以及运行时 hook 计数。

- **AI 结构**：`AI_Controller_C` 跑行为树（`BT_Grunt` 等，在 `/Game/ProjectLima/Blueprints/AI/BehaviourTrees/`），黑板是 `BB_AI_Base`
- **三处目标引用**，类型都是 `CH_LimaCharacter_C*`：
  - `AI_Controller_C.LimaCharacter`
  - `CH_AI_Base_C["As CH Lima Character"]`
  - 黑板 `Target`（object）
- **其他黑板键**：
  - 向量：`PlayerActualLocation`、`PlayerLocation`、`MoveToLocation`
  - bool：`CanSeeTarget?`、`InAttackCooldown?`
  - enum：`EnemyState`（实测值 1 和 2 来回切换）
- **`AI_Controller_C.SetPlayerLocation`**：约 11 Hz，把目标位置写进 `PlayerActualLocation`
  - 改了三处引用以后，这个值立刻变成替身的位置，误差 0
- **`BTTask_FocusPlayer`**：调 `AIController.K2_SetFocus(目标)`，跟着引用走
- **`BTTask_MoveToLocation`**：读黑板 `MoveToLocation`
  - 这个点由 EQS 写入，用的是原生写法，没有经过 `SetValueAsVector`
  - `EQS_Context_PlayerActor.ProvideSingleActor` 被调用过，具体返回什么没查
- **感知**：`PawnSensing`，`bOnlySensePlayers = true`，视距 3500，听觉 1400
  - 只感知有 PlayerController 的 Pawn，所以替身默认看不见
  - 感知回调 `BndEvt__AI_Controller_PawnSensing_..._SeePawnDelegate` 会把黑板 `Target` 改成看到的那个 Pawn，并置 `CanSeeTarget? = true`
  - 实测：看见房主后，`Target` 从替身被改回房主

## 开火的瞄准

出处：在 `FireProjectileFromPool` 之前的 60 次引擎调用环形缓冲。

```
SceneComponent:GetSocketLocation  self=CharacterMesh0  Fire_L     -- 枪口
GameplayStatics:GetPlayerCharacter (WorldContext = 敌人)          -- 写死 0 号玩家 = 房主
Actor:K2_GetActorLocation  self=房主
KismetMathLibrary:FindLookAtRotation
KismetMathLibrary:RandomUnitVectorInConeInDegrees                  -- 散布
KismetMathLibrary:MakeTransform
GameplayStatics:GetPlayerController
<< PC_LimaPlayerController_C:FireProjectileFromPool
```

- 三处引用都指向替身、焦点也在替身身上时，32 发子弹仍然对准房主：
  - 偏离房主 0.3–10°
  - 偏离替身 26–164°
- 敌人走到替身旁边以后，会回头朝 2000 单位外的房主开枪

## 实验结果

| 实验 | 做法 | 结果 |
|---|---|---|
| 生成替身 | `SpawnActor(CH_LimaCharacter_C)`，不附身 | 正常，游戏稳定。`pc().Pawn` 和 `player()` 仍是房主；HUD 没有重复。替身会 tick，自带武器对象，生命 110 |
| 改目标（一次） | 改三处引用 + `K2_SetFocus` | 引用没有被改回；`PlayerActualLocation` 等于替身位置。但 `CanSeeTarget?` 一直为假，不开火 |
| 放开感知 | `PawnSensing.bOnlySensePlayers = false` | 替身被看见（13 次）。但看见房主时 `Target` 被改回房主，子弹仍打房主 |
| 每 0.5 s 重设目标，替身离房主 2000 | 同上，循环重设 | 约 10 s 后敌人走到替身身边，之后一直保持 280–870 的距离。**移动跟着 `Target` 走**；开火仍打房主 |
| 子弹改向 | hook `ActivateProjectile?` 记下子弹，下一帧把 `ProjectileMovement.Velocity` 改成指向替身（保持速率 1100） | 28/28 改向成功，`ApplyPointDamage` 打在替身上（18.75）；替身设了 `bCanBeDamaged = false`，不掉血 |
| 后置回调 | `RegisterHook(path, pre, post)` 挂在 SeePawn 上 | 注册成功，但后置回调 0 次（前置 26 次）。**本版 UE4SS 的蓝图函数 hook 不能用后置回调** |
| 结构体出参 | `NavigationSystemV1.K2_ProjectPointToNavigation(..., o, ...)` | 返回 true，但 `o.ProjectedLocation` 为 nil。**结构体出参不会写回 Lua 表**（标量出参可以，见 `GetHealth`） |

子弹类：
- `BP_EnemyProjectile_Master_C`（`/Game/ProjectLima/Blueprints/Projectiles/`）
- 子类 `BP_PRJ_Enemy_Basic_C`（`.../Projectiles/EnemyProjectiles/`），它重写了 `ActivateProjectile?(bool, AController)`，所以父类和子类都要 hook
- 字段：`ProjectileMovement`、`Event Instigator`（开火的 AI 控制器）、`BaseDamage`、`ProjectileAlive?`

## 设计（房主权威仇恨）

1. **替身**：房主为每个远端玩家生成一个 `CH_LimaCharacter_C`，每帧移到该玩家的位置（用傀儡同一份插值）
   - 隐藏
   - `bCanBeDamaged = false`
   - 胶囊不挡房主（碰撞设置待定）
   - 可见的傀儡仍用现在的 Quinn 网格
2. **选目标**：房主为每个敌人选目标，每 0.5–1 s 评估一次，带滞后
   - 优先最近打它的人，其次最近且可见的玩家
3. **贯彻目标**：写三处引用和焦点
   - 在 `BTTask_*` 的 `ReceiveExecuteAI` / `BTService_InRangeForChase.ReceiveTickAI` 的前置 hook 里重设黑板 `Target`，让任务读到正确的目标
   - 主循环里也每 tick 低频重设，抵消 SeePawn 的覆盖
   - 所有敌人设 `bOnlySensePlayers = false`，替身才能被"看见"
4. **子弹**：沿用 3.4 的转发，但按敌人的**指定目标**发给对应客户端，不再按最近距离
   - 房主自己那颗子弹在下一帧改飞向替身：房主能看到敌人在打队友，自己也不会挨打
   - 散布偏移照旧按"相对房主的直线"计算（瞄准本来就是对房主算的）

## 实现（3.4b，`src/lua/VBMP/Scripts/aggro.lua`）与双实例验证

- **替身不能用 `SetActorHiddenInGame` 隐藏**：PawnSensing 会跳过隐藏的 Pawn，敌人就一直"看不见"替身，转去搜索、走远（双实例 2026-11-05 第一轮）
  - 改为 `RootComponent:SetVisibility(false, true)` 只隐藏组件
- **站位**：EQS 站位点以 0 号玩家为中心，敌人会慢慢漂向房主，"最近玩家"规则随之来回切换（第二轮，3 s 内切走）
  - 修法一：`BTTask_MoveToLocation` 的前置 hook 里把 `MoveToLocation` 平移 (替身 − 房主)
  - 修法二：切换要求近一半，并锁定 4 s
- **第三轮结果**（步兵生成在 B 的替身旁，A 在 1200 外）：
  - 20 s 内一直锁定替身，距离替身 300–900
  - 24 发子弹全部转给 B 并在 B 端重放，B 110→35
  - A 被打 0 次，20 发房主子弹改向
- **主机打一下**（`ApplyPointDamage`，instigator 是房主）：日志 `enemy #1 -> host (hit it)`，之后追 A、打 A
- **B 离开**：替身删除、敌人还给房主，没有崩溃
  - 删除后替身在 GC 前仍能被 `FindAllOf` 找到（`bActorIsBeingDestroyed = true`），所以本地玩家一律用 `pc().Pawn`
- **顺带修了 `main.lua` 的 `realTime()`**：主菜单控制器被拆掉后，缓存的世界对象让 `GetRealTimeSeconds` 永远失败，网络循环卡死（实例在菜单停留较久时出现）。现在失败就重新查找

## 风险和未知

- 替身是完整的玩家角色（会 tick 相机和武器逻辑）。不清楚的有：
  - 游戏逻辑会不会把它当成玩家（统计、死亡判定、存档）
  - 多个替身对性能的影响
- 代码里不能再用 `FindFirstOf("CH_LimaCharacter_C")` 找本地玩家，要用 `pc().Pawn`（VBMP、VBTools 都要检查）
- 子弹改向晚一帧：近距离（< 50 单位）的子弹可能已经打中房主
- 只验证了步兵（`BP_PRJ_Enemy_Basic_C` 和 `BasicShoot`/`AttackZero_Fire` 这条路）。下面这些多半也是 `GetPlayerCharacter(0)`，要逐个验证：
  - 近战、伤害场、追踪弹（`HomingFast`/`HomingStrong`）
  - 精英的 ProjectileHelper
  - boss
- `CanSeeTarget?` 在指定目标是替身时，可能因为看见了房主而为真（会对替身隔墙开火）。子弹会撞墙，影响不大
- EQS 站位点（`MoveToLocation`）一开始仍围着房主算，约 10 s 后才转去追替身。要更快，得在 `BTTask_MoveToLocation` 的前置 hook 里平移这个点；投影到导航网格需要能拿到结构体出参的接口，或者自己做射线投影
