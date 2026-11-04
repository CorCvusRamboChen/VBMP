# 架构（草案）

## 总体

- **房主权威**：房主运行完整的单机游戏，敌人 AI、伤害、关卡生成、破坏都在房主那里计算。客户端也运行游戏，但关闭或接管随机和权威逻辑，只发送意图（移动、开火、交互），并展示房主下发的结果。
- **远端玩家 = 傀儡 Actor**：不复制 `CH_LimaCharacter_C`（893 个函数的单机蓝图，到处默认自己是唯一的玩家）。在每台机器上为其他玩家各生成一个傀儡，由网络数据驱动。
  - 房主那边的傀儡还要额外承担：World Partition 流送源、导航网格生成器、敌人感知目标、伤害接收者
- **实现形态**：先用 UE4SS Lua 做原型，验证游戏侧的接入点；网络和性能相关的部分用 UE4SS C++ mod。

## 层次（目标）

```
ue_wrap   只封装 UE4SS/反射调用，不写玩法
game      对游戏蓝图的访问：玩家、GameMode、敌人、武器、破坏（只通过 ue_wrap）
net       传输层：先 UDP，之后换 SteamNetworkingSockets（游戏自带 steam_api64 v161）
sync      各同步系统，每个系统写明权威方和消息格式
```

## 同步入口（来自 Phase 0 转储）

| 系统 | 权威 | 入口 |
|---|---|---|
| 关卡生成 | 房主 | `GM_LimaGameMode_C.GenerateWorld` / `AssignScenarios`，结果存在 `Chosen*Scenario` 等变量；客户端用 `BP_ScenarioAssigner_C.FinalAssign`、`PC_LimaPlayerController_C.SetLayerStatus` 重放 |
| 玩家位置 | 各自客户端 | 读：`K2_GetActorLocation`/控制旋转；写：傀儡 |
| 开火 | 发起者表现、房主判定 | `BP_Weapon_Base_C.FireServerProjectile`（产生伤害）/ `FireProjectileFake`（只有表现） |
| 敌人伤害、死亡 | 房主 | `CH_AI_Base_C.ApplyDamage` → `SetHealth` → `DeathEvent` |
| 玩家受伤 | 房主 | `CH_LimaCharacter_C.DealDamageToPlayer` |
| 破坏 | 房主 | `BP_ChaosPoolManager_C.ChaosFromPool(...)`；物件状态 `BP_DestructibleItem_GC_Master_C.State` / `ForceObjectState` |
