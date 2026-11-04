# 同步设计（草案 v1）

依据：Phase 0 转储（build 23764881）、资源清单、`research/vbtools-01-difficulty-mods.md`。标 ❓ 的是还没验证的假设，要先用"事件探针"（见末尾）在实际游戏里测过再写实现。

## 1. 总原则

- **房主权威**：房主跑完整的游戏逻辑（敌人 AI、伤害、关卡生成、破坏、掉落、存档）。客户端也跑同一个游戏，但凡是"会产生结果"的逻辑都要关掉或接管，只发送意图（我在哪、我朝哪开了枪、我想拿这个东西），并展示房主下发的结果。
- **两台机器的世界尽量一样**：先同步关卡生成的选择（`GM_LimaGameMode_C` 的 `Chosen*Scenario`、Data Layer），这样所有摆放的物体在每台机器上都存在，名字也一样。之后只需要同步"变化"。
- **只同步对玩法有影响的东西**：碎片长什么样、火花往哪飞，允许每台机器不同。

## 2. 物体身份：两台机器怎么认出"同一个东西"

| 类别 | 例子 | 身份 | 依据 |
|---|---|---|---|
| 关卡里摆放的物体 | 可破坏物、门、宝箱、终端、开关、商店 | **Actor 名字里的 `UAID`**（编辑器分配，打包进关卡，每台机器一样），加上所属关卡资源名。同一个子关卡被摆了两次时，再加上取整到 10 cm 的坐标来区分 | 转储里有 543 个 `…_C_UAID_D8BBC116F90D…_1681361898` 这样的可破坏物；游戏存档的 `DestroyedActors : TArray<FName>` 也是按名字记的，`DisabledRunIDActors : TArray<FGuid>` 按 GUID 记 |
| 运行时生成的物体 | 敌人、掉落物、金钱球、宝箱里刷出的模组 | **房主分配的 NetID**（递增整数）。房主检测到生成时广播"生成消息"（类路径、位置、参数），客户端生成自己的副本，并维护 NetID → 本地 Actor 的映射 | 敌人有 `SpawnEnemyImmediate`、`GM.AddEnemyPool`/`RemoveFromEnemyPool` 可以 hook |
| 对象池里的物体 | 玩家子弹、敌人子弹、Chaos 力场、伤害数字、TinyDST | **不同步对象本身，只同步"事件"**。对象池会复用对象，它们不能当身份用 | `BP_ProjectilePoolManager`、`BP_EnemyProjectilePool_Manager`、`BP_ChaosPoolManager` |
| 全局状态 | 关卡进度、生态区、任务、难度、时间 | 字段快照 | `GM.GetGameLevel`、`Level/OverallTier/Biome/CurrentBiomeTier`、`MasterRunProgress/SubRunProgress`、`CurrentActiveMission` |

## 3. 场景破坏

破坏分四层，越往下越不需要精确：

### L1 力场事件（视觉近似）
- 房主 hook 产生破坏的入口，把参数广播出去；客户端用**完全相同的参数**调用自己的同一个函数，本地的 Chaos 模拟算出相似的碎裂。
  - `BP_ChaosPoolManager_C.ChaosFromPool(Transform, ExternalStrain, InternalStrain, ElementalType, RemoveAnchors, RadialMagnitude, DirectionType, VelocityDirection, WakeMega)`：子弹类力场
  - 冲刺：`FS_ChaosField_Continuous_Dash`；近战：`CH_LimaCharacter_C.PlayMeleeSwipe(DestructionSwipe?)`；小型破坏：`PC_LimaPlayerController_C.SpawnTinyDST(Location)`；爆炸、手雷、敌人攻击 ❓（入口待探针确认）
- 一条消息大约 80 字节。激烈战斗时每秒几十条，带宽完全没问题
- **客户端自己不能产生破坏**：客户端玩家开的枪，在客户端上只走"假子弹"（`BP_Weapon_Base_C.FireProjectileFake`），真子弹由房主生成，力场也由房主广播。否则同一面墙会被打两次

### L2 物件状态（玩法一致）
- 每个可破坏物的"状态"由房主说了算：`BP_DestructibleItem_GC_Master_C.State : EObjectStateTypeEnum`，可以用 `ForceObjectState()` 强制设定；被彻底摧毁的物体进 `DestroyedActors`
- 房主在状态变化时发送"UAID X → 状态 S"（可靠消息）。客户端如果自己的状态不一样（比如力场没把它打碎），就强制设成房主的状态
- 结果：就算 L1 的碎法略有不同，"哪面墙没了、哪条路通了、哪个掩体还在"在所有人那里都一致

### L3 碎片（不同步）
- 碎片是纯视觉效果，并且会被 `BP_ChaosPoolManager` 回收
- 碎片砸到敌人造成的伤害（`CH_AI_Base_C.CalculateHealth` 里的 `FromDebris?`）只在房主那里计算

### L4 中途加入
- 新加入的玩家先按房主的选择生成关卡，再收到完整的 `DestroyedActors` 和"状态 ≠ 初始"的物件列表，加载时直接设成最终状态，不播放碎裂过程

### 可移动的物理物体
- 可投掷的石块（`BP_DST_M_ThrowableRock_*`）、物理道具（`BP_PhysicsObject_Master`）：房主以 10–20 Hz 发送正在运动的物体的位置和旋转，客户端插值显示，物体静止后停止发送（参考 Multivoid 的做法）
- ❓ 这些物理物体由 Havok 还是 Chaos 驱动（游戏里同时有两套插件），对同步方式没有影响，但会影响"让客户端的物体停止自己模拟"该用哪个开关

## 4. 其他信息

| 信息 | 权威 | 频率 / 通道 | 入口 |
|---|---|---|---|
| 玩家位置、朝向、移动状态 | 各自客户端 | 30 Hz，不可靠，接收方按时间戳插值（幽灵傀儡已经验证过这套显示方式） | `K2_GetActorLocation`、控制旋转、冲刺/钩爪/滑铲状态 |
| 玩家开火 | 开火方立刻显示，房主判定 | 事件，可靠 | 客户端：`FireProjectileFake`；房主：`FireServerProjectile(Damage, Transform, Rotation, VelocityMult, Pool, IgnoreActor)` |
| 敌人位置和动作 | 房主 | 10–20 Hz 快照 + 攻击事件 | `CH_AI_Base_C` 的 Transform、`PrimaryAttack`…`QuartinaryAttack` |
| 敌人血量、死亡 | 房主 | 变化时，可靠 | `ApplyDamage` → `SetHealth` → `DeathEvent`；客户端的敌人不自己扣血 |
| 敌人子弹 | 房主 | 事件 | `PC_LimaPlayerController_C.FireProjectileFromPool(Transform, Type, Controller)` |
| 玩家受伤 | 房主 | 事件 | `CH_LimaCharacter_C.DealDamageToPlayer(double)`，房主对远端傀儡判定后发给对应客户端 |
| 掉落、金钱、拾取 | 房主 | 生成事件 + 拾取请求 / 确认 | 敌人掉落 `SpawnMoney/SpawnAmmo/SpawnHealth/ItemPickupSpawn`；拾取由客户端请求，房主确认后才生效 |
| 门、开关、终端、宝箱 | 房主 | 交互请求 → 广播结果 | `GI_LimaGameInstance_C.SaveToSwitchActors(Name, On, Activated)`、`SwitchedActors` |
| 关卡生成、生态区切换 | 房主 | 进入关卡前一次性发送 | `GM.GenerateWorld/AssignScenarios/TransitionBiome`，`PC.SetLayerStatus` |
| 各自的装备和模组 | 各自客户端 | 变化时 | 只用于在别人那里显示外观和特效；伤害仍由房主按发送方的装备计算 ❓（需要研究房主如何"代替"远端玩家计算模组效果） |
| 存档 | 只有房主写 | — | **客户端必须禁止写入局内存档**（hook `GI.SaveGameData`），否则联机时客户端会把一个奇怪的状态存进自己的 `LimaSaveGame.sav` |
| 时停、慢动作 | 待定 | — | `PC.FreezeTime/ResumeTime`、`ABL_ActivateChronoHold?`，见 `docs/status.md` 设计问题 1 |

通道：不可靠（位置快照）+ 可靠有序（事件和状态）。传输层先用 UDP，之后换 SteamNetworkingSockets。

## 3b. 新发现：可破坏物是"预破坏"设计（2026-11-04）

- 大多数可破坏物的基类是 `BP_PreDestructibleItem_Master_C : AStaticMeshActor`。平时只是静态模型，被打中时调用 `DestroyObject(FVector Location, bool IsFieldExplosive?, int32 FaceIndex)`，再 `Swap` → `SpawnGC`，换成 Geometry Collection 去碎裂
- 其他入口：`DashDestroy(Location, Size)`、`MegaDestroy(LocationOfHit)`、`WakeObject(ElementalType, HitIndex, FromDash?, Origin)`、`PermanentlyDestroy()`、`ReceiveAnyDamage(...)`、`DeathEvent()`
- 这对 L1/L2 都很有利：**破坏入口就在物体自己身上，而物体有跨机器一致的 UAID 名字**。房主广播"物体 UAID + 函数 + 参数"，客户端找到同名物体调用同一个函数，就能得到同样的"换成碎裂体"
- `BP_ChaosPoolManager.ChaosFromPool` 负责之后推动碎片的力场；两者都要回放
- **2026-11-05 更正**（`research/phase3-06-destruction.md`）：
  - 破坏实际走的是伤害路径：`ReceiveAnyDamage` 扣 `CurrentHealth`，归零后 `Swap`
  - 单独调 `DestroyObject` 不会碎；`ChaosFromPool` 也碎不了完好的物体
  - 3.5 的实现同步的是"物体碎了"事件，重现方式是施加致命伤害

## 5. 下一步：事件探针（单机就能做）

> 🔧 已实现：`src/lua/VBTrace/`。探针挂了 56 个入口（蓝图 + 原生），每 10 秒在日志里输出各事件的次数，事件明细写入 `%LOCALAPPDATA%\VOIDBREAKER\Saved\VBTrace_events.log`。Ctrl+F9 开始/停止录制破坏，录到的内容存在 `VBTrace_recording.lua`；Ctrl+F11 按原来的时间和参数回放，物体按 UAID 名字找回来。

在实现同步之前，先在一个人的游戏里测出真实数据：

1. **VBTrace 探针 mod**：hook 上面表格里的所有入口，只记录不修改。记下每种事件每秒发生多少次、参数是什么、由谁触发。打一场普通战斗和一场 boss 战，得到一张"事件频率表"，用来确认入口找得对不对、带宽够不够、有没有漏掉的破坏来源（爆炸、手雷、敌人攻击）
2. **破坏回放实验**：录下一段战斗中所有的 `ChaosFromPool` 调用，然后读档回到战斗前，按热键用录下的参数重新调用一遍，看墙会不会以相似的方式碎掉。这在一台电脑上就能验证"客户端用房主的参数重现破坏"这条路走不走得通
3. 两个实验都通过后，再开始写网络层
