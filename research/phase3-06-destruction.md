# Phase 3.5 调查和实现：场景破坏同步

build 23764881，2026-11-05。单实例追踪：Biome_05，`BP_DST_M25_4x4_Floor_C` 地砖和 `BP_GDST_M29_Window_4x4_D_C` 玻璃。之后做了双实例验证。

## 可破坏物的结构（CXX 转储 + 对象转储）

- **放置在关卡里的可破坏物**都是 `BP_PreDestructibleItem_Master_C : AStaticMeshActor` 的子类
  - Biome_05 转储里最多的几类：`BP_GDST_M29_Window_4x4_D_C`（54）、`BP_DST_M25_x4_Pillar02_C`（48）、`BP_DST_M25_4x4_Floor_C`（48）、`BP_DST_M23_x8_MetalBeam_NoCol_C`（40）、`BP_DST_M25_4x4_Wall_C`（28）
  - 中间层：`..._Master_Building_C`、`..._Master_Building_Glass_C`、`..._Master_Prop_C`、`..._Master_Prop_Throwable_C`
- **各层的重写**：
  - Building 重写 `MegaDestroy`/`WakeObject`/`CALL_DestroyBuildingSwapEvent`，自己有 `BatchDestroyEvent`、`DestroyNearbyBuildingPieces`
  - Glass 重写 `ReceiveAnyDamage`/`WakeObject`，自己有 `DestroyGlassManual`
  - Prop 重写 `WakeObject`
- **字段**：`CurrentHealth`（地砖、玻璃都是 500）、`Swapped?`
- **对象名**：带 UAID，例如 `BP_DST_M25_4x4_Floor_C_UAID_D8BBC116F90D4F7102_c290eee8a16c5ac0_1466998180`
  - 对象在运行时生成的关卡实例包里：`/…/LV_B05_BT_SUB_15/_Generated_/2ZKI9RMLI6JHXD5R5A03VWMDN_LevelInstance_17.LV_B05_BT_SUB_15:PersistentLevel.…`
  - 完整路径不适合当跨机器的身份
  - **双实例实测**：两边最近的 4 块地砖和 2 块玻璃，名字和坐标完全一致（两边读的是同一个存档）

## 什么让它碎（追踪结果）

| 做法 | 结果 |
|---|---|
| `BP_ChaosPoolManager_C.ChaosFromPool(Transform, 12000, 1200, 0, false, 55, 0, 向下, false, {})`，在地砖上 | 什么都没发生。力场只推动已经换成碎裂体的部分。之前 VBTrace 录到的大量 `ChaosFromPool`（每发子弹一次）不会导致破坏 |
| `ApplyPointDamage(地砖, 50, …, DamageType_Normal_C)` | `ReceiveAnyDamage`，`CurrentHealth` 500→450 |
| 致命伤害（600） | `CALL_InitialDestroyEffects` → `Building.BatchDestroyEvent` → `Building.CALL_DestroyBuildingSwapEvent` → `Master.Swap` → `Building.WakeObject(0,0,false,0)` → `ReceiveAnyDamage`；`Swapped? = true`，多出一个 `BP_DestructibleItem_GC_Master_C` |
| 直接调 `DestroyObject(位置, false, 0)` | 只有这一个调用，`Swapped?` 仍为假，没有碎 |
| 对玻璃施加致命伤害 | `Glass.ReceiveAnyDamage` → `BatchDestroyEvent` → `CALL_DestroyBuildingSwapEvent` → `Glass.DestroyGlassManual`。**没有 `Swap`**，`CurrentHealth` 不变（仍是 500），玻璃网格消失 |

结论：
- 破坏走普通伤害路径（血量归零）
- 可以用来表示"碎了"的信号：`Master.Swap`、`Master.CALL_InitialDestroyEffects`、`Building.BatchDestroyEvent`、`Glass.DestroyGlassManual`
- 重现破坏：施加致命的 `ApplyPointDamage` 即可

## 实现（`src/lua/VBMP/Scripts/destruction.lua`，消息 `DST_BREAK = 18 "<s1fff"`）

- **身份**：键 = actor 名 + 坐标（取整到 50）
  - 接收方按类名 `FindAllOf`（结果缓存 2 s），找同名、距离 150 以内的那个
- **检测**：四个"碎了"的信号都 hook，hook 里只记录到队列（同一个物体去重）
- **发送**：双方都发自己的破坏，不管起因（子弹、冲刺、爆炸、敌人、重放的子弹）。客户端发给房主；房主应用后转发给其他客户端，不发回来源
- **应用**：在网络循环里施加 `CurrentHealth + 1` 的点伤害
  - 先把键记为已知，所以这一下以及由它连带碎掉的物体都不会再发回去
  - 物体还没流送进来的，每 2 s 重试一次，最多等 5 分钟
- **中途加入**：房主记录本关卡所有破坏，新玩家 HELLO 时一次性发过去
  - 切换关卡时清空记录；从"不知道关卡"到"知道关卡"不算切换

## 双实例验证（2026-11-05）

- **A→B**：A 打碎地砖 1，B 同一秒内应用，`Swapped? = true`
- **玻璃 A→B**：A 打碎玻璃 1，B 应用后玻璃网格组件被移除；A 这边是网格隐藏。路径不同，结果一样
- **B→A**：B 打碎地砖 3，A 应用
- **计数**：A 发 2 收 1，B 发 1 收 2，没有回声
- **中途加入**：A 先打碎地砖 2 和 4，B 加入后这两块立刻碎掉
  - 第一版把这份补发清掉了：加入后第一次知道关卡名时，被误当成换关。已修复并复测

## 缺口

- **只同步"碎了"，不同步"受损"**：A 打掉 300 血、B 打掉 300 血，两边都不会碎（单机里会碎）
  - 以后可以让客户端把对可破坏物的伤害当成意图发给房主（同敌人命中）
- **客户端仍然在本地产生破坏**，并作为事实上报，房主只核对物体存在。按"房主权威"更严格的做法：客户端本地不破坏，只发伤害意图
- **碎片的物理和力场**（`ChaosFromPool`）不同步：碎法、碎片飞向各自模拟
- **其他物体没有验证**：只验证了建筑地砖和玻璃。道具（Prop/Throwable，例如油桶会爆炸）、整栋建筑倒塌（`DestroyNearbyBuildingPieces` 连锁）、冲刺破坏都没有验证
- **关卡一致性**：前提是双方世界一样。目前两边各自生成世界，同一个存档时名字和坐标一致；世界生成同步还没做
