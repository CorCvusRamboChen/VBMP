# Phase 0 / 03 — UE4SS 反射转储与可行性结论

- 日期：2026-11-04，build `23764881`
- 方法：UE4SS experimental 1196 + 自写 `VBMPDump` mod。阶段 1 在主菜单，阶段 2 在关卡内，各自导出 USMAP、UHT 头文件、CXX 头文件、对象列表
- 运行情况：UE4SS 正常注入，所有地址扫描成功，两个阶段 4 步全部 `ok`，无崩溃（`UE4SS.log` 1,739 行）
- 原始转储：gaming PC `C:\Users\User\vbmp\dumps\23764881-20261104-024205\`，本机副本在 `research/_local/dumps/`（**不进仓库**）

## 引擎事实（已确认）

| 项 | 值 | 来源 |
|---|---|---|
| 引擎 | **UE 5.7.4**，开发商分支 `++ProjectLimaDepot+Main`，CL 4091 | usmap 文件名 + UE4SS `Found EngineVersion: 5.7` |
| 构建 | Shipping，Stats 关闭，非模块化（单 exe） | UE4SS 日志 |
| FName 哈希 | Murmur32 | UE4SS 日志 |
| 游戏 C++ 模块 `VOIDBREAKER` | **只有 UI 和 `UPL_GameStatics`**（存档队列、平台判断、取根控件），没有任何玩法 C++ | UHT 转储 |
| 物理插件 | 除了 Chaos，还有 Havok（`HavokPhysicsExtensions`、`HavokGeometryProcessing`、`HavokDebug`） | UHT 包列表 |
| 已编译进来的网络相关模块 | `OnlineSubsystem`、`OnlineSubsystemSteam`、`SteamCore`、`SteamCoreWeb`、`IrisCore`、`NetCore`、`OodleNetworkHandlerComponent` | UHT 包列表 |

**结论：玩法 100% 是蓝图。** 所有我们需要 hook 或调用的东西，都是带反射信息的蓝图函数，UE4SS 可以直接按名字 hook 或调用，不需要找 C++ 函数地址。这是可行性最关键的利好。

## 关键蓝图（联机同步的切入点）

### 玩家 `ACH_LimaCharacter_C : ACharacter`（698 个变量，893 个函数）
- 第一人称组件：`FirstPersonCamera`、`FirstPersonArms`、`SK_Gloves2B`、`RecoilAnimation`
- 武器是 4 个 ChildActorComponent：`PrimaryGun`、`SecondaryGun`、`TritaryGun`、`QuartaryGun`，类型都是 `BP_Weapon_Base_C`
- **`WorldPartitionStreamingSource`**：World Partition 的流送由玩家驱动。房主那边要为每个远端玩家各放一个流送源，否则远端玩家身边的关卡不会加载
- **`NavigationInvoker`**：导航网格在玩家附近动态生成，远端玩家附近也需要，否则敌人 AI 在那里走不动
- `PawnSensing`：敌人靠它感知玩家，远端傀儡需要能被敌人"看见"
- 关键函数：`DealDamageToPlayer(double)`、`GetPlayerHealth`、`AddHealth`、`AddCurrency`、`EnemyReceivedDamage(FSTR_EnemyDamage)`、`StartFire`、`Dash`、`MeleeSwing`、`GetCurrentlyEquippedWeaponRef`、`FreezePlayer`/`UnfreezePlayer`、`CinematicLock(...)`

### GameMode `AGM_LimaGameMode_C : AGameMode`
- 世界生成：`GenerateWorld`、`CreateBiome`、`AssignScenarios`、`ChooseRandomRedCombat`、`ChooseRandomOrangeArea`、`ChooseRandomBossLocation`、`SetShops`、`SetUnchartedAreas`、`SetFastTravelPoints`、`TransitionBiome`
- 选择结果存在变量里：`ChosenRedScenario`、`ChosenOrangeScenario`、`ChosenBossScenario`、`AllScenarios`、`Red_NotAssigned`、`Orange_NotAssigned`、`NumberOfShops/Teleporters/ChestAreas/Obelisks/...`
- 进度：`Level`、`OverallTier`、`Biome`、`CurrentBiomeTier`、`MasterRunProgress`、`SubRunProgress`，读写接口 `GetGameLevel`/`SetGameLevel`
- 敌人管理：`EnemyPool`、`ChasingEnemies`、`AddEnemyPool`/`RemoveFromEnemyPool`、`CreateChasingEnemy`
- 存档：`LoadSaveGame`、`PopulateWorldFromSave`、`Populate World from Previous Run`

→ **关卡同步方案确定**：房主正常运行 `GenerateWorld`；hook 它结束的时机，读出 `Chosen*Scenario`、各数量和激活的 Data Layer，下发给客户端；客户端跳过随机，按结果执行（`BP_ScenarioAssigner.FinalAssign`、`BP_DataLayerSwitcher.EnableDataLayer`、`PC_LimaPlayerController.SetLayerStatus`）。

### 控制器 `APC_LimaPlayerController_C`
- Data Layer 控制：`SetLayerStatus(UDataLayerAsset*, EDataLayerRuntimeState)`、`StartStreamingCheck`、`StreamingDone`
- 敌人子弹池：`FireProjectileFromPool(Transform, Enum_EnemyProjectileType, Controller)`
- **全局时间操作**：`FreezeTime`、`ResumeTime`、`ABL_ActivateChronoHold?(bool, duration)`、`EndMissionSlowdown`。多人时这是**设计问题**：一个人开"时停"，其他人怎么办？
- 其他：`SpawnTinyDST(Location)`（小型破坏物）、`CreateDamageNumber(...)`、`DissolveWorld`/`UnDissolveWorld`

### 武器 `ABP_Weapon_Base_C : AActor`
- **`FireServerProjectile(Damage, Transform, Rotation, VelocityMult, Pool, IgnoreActor)`** 和 **`FireProjectileFake()`**：开发者已经把"真正产生伤害的子弹"和"只做表现的假子弹"分开了，正好对应"房主算伤害，客户端只看表现"
- 子弹是对象池里的实体（`BP_ProjectilePoolManager`），不是射线检测。同步"开火事件"就够，不需要同步每颗子弹
- 开火模式和改装件来自 DataAsset（`UPDA_FireModes_C`、`UAC_Mod_PRJ_Master_C`）

### 敌人 `ACH_AI_Base_C : ACharacter`
- 伤害：`ApplyDamage(FHitResult, FVector Direction, double)` → `SetHealth(...)` → `DeathEvent(bool BypassDrops)` / `PreDestroy(...)`
- 状态读取：`GetHealth`、`CurrentlyStaggered?`、`GetEnemyAttacking?`
- 攻击：`PrimaryAttack`、`SecondaryAttack`、`TritaryAttack`、`QuartinaryAttack`
- 生成：`SpawnEnemyImmediate(bool KnowsPlayer)`
- 掉落：`SpawnMoney`、`SpawnAmmo`、`SpawnHealth`、`ItemPickupSpawn`
- 伤害负载结构 `FSTR_EnemyDamage { double IncomingDamage; bool EnemyFrozen; ACH_AI_Base_C* EnemyReceivingDamage; UDamageType* DamageType; }`

### 破坏
- **`BP_ChaosPoolManager.ChaosFromPool(Transform, ExternalStrain, InternalStrain, ElementalType, RemoveAnchors, RadialMagnitude, DirectionType, VelocityDirection, WakeMega)`**：子弹类破坏力场的**统一入口**，参数完整
- 同步方案：房主 hook 这个函数，把参数广播出去；客户端用同样的参数调用自己的 `ChaosFromPool`
- `BP_DestructibleItem_GC_Master_C : AGeometryCollectionActor` 带 `State`（`EObjectStateTypeEnum`）和 `ForceObjectState()`，可以用来在中途加入时把物件直接设成"已破坏"状态
- `BP_BuildingDestructionManager` 这次没加载到（当前关卡里可能没有建筑破坏），以后在有建筑的关卡里再转储一次

## 可行性结论

**可行，风险比计划之初低。** 原计划的两大风险：

| 风险 | 结论 |
|---|---|
| 能否创建额外的玩家实体 | 不需要复制 `CH_LimaCharacter`（它是 893 个函数的单机巨型蓝图）。远端玩家用自己生成的傀儡 Actor 表示，同时在房主那边补上 `WorldPartitionStreamingSource`、`NavigationInvoker`，并让敌人能感知到它。全部是蓝图层面的操作，UE4SS 能做到 |
| 环境破坏能否同步 | 有统一入口 `ChaosFromPool`，加上物件状态 `State`/`ForceObjectState`，同步事件即可，碎片外观允许不同 |

新发现的设计问题（需要你来决定）：
1. **时停/慢动作类能力**（`ChronoHold`、`FreezeTime`）在多人下怎么处理：全员生效、只对施放者生效，还是禁用
2. **玩家死亡和复活**：单机是直接结束这一局（`BP_EndRun`、`RespawnPlayer`），多人要不要做倒地/复活
3. **局外成长**（存档里的永久升级、解锁的武器）：每个人用自己的存档，还是用房主的

## Phase 0 结束，进入 Phase 1 的建议

Phase 1 目标：**两台电脑，房主的世界里出现一个由客户端位置驱动的傀儡**。不同步战斗，只同步位置和朝向。

1. 建立仓库骨架（`CLAUDE.md`、`docs/`、`src/`），先用 UE4SS 的 **C++ mod**（需要 UE4SS 的 C++ 模板和 VS 2022）
   - 也可以先用 Lua 做最小原型，验证生成傀儡和读写玩家位置，再迁移到 C++
2. 网络层先用最简单的 UDP（局域网两台电脑），等傀儡能动了，再换 SteamNetworkingSockets
3. 需要第二台装了游戏的电脑：这台笔记本还没装 VOID/BREAKER（同一个 Steam 账号可以在两台电脑上安装，但同一时间只能有一台在线运行游戏）。**联机测试最终需要两个 Steam 账号**
