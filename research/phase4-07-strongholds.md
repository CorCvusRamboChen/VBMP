# Phase 4.7 — 据点 / 波次任务 / 竞技场，替身的重叠事件

- 日期：2026-11-05，build 26439385（Biome_05 的 `BP_Stronghold_Frozen_C`，(33063, -79837)）
- 来源：CXX 头文件、对象转储、双实例实测

## 类

- `/Game/ProjectLima/Blueprints/AI/Waves/BP_Stronghold_Master`（父类），子类 `BP_Mission_WaveSpawner`、`BP_Mission_EliteSpawner`（Waves/）、`BP_Mission_MiniBoss`（Strongholds/），具体据点 `BP_Stronghold_Storm/Overclocked/Fortified/Frozen/...`
- `BP_BossFightArena_Master`（Waves/）是单独的类（父类 AActor），也有 `StrongholdCompleted()`（无参数）
- 字段：`Completed?`、`StrrongholdCurrentlyActive?`（原文拼写）、`ShieldActive?`、`MasterEnemyPool`

## 流程（实测，A 的日志）

1. 玩家进入：`CALL_PlayerOverlappedStart()` → `ActivateShield?(true)`（护盾把人关在里面）→ 刷怪
2. 每死一个：`CALL_EnemyDestroyed(Enemy, BypassDrops?, DeathReason)`
3. 清完最后一波：`SpawnLoot()` → `StrongholdCompleted(GiveReward? = true)` → `RemoveShieldAnimation()` → `ActivateShield?(false)`，`Completed?` = true
- 打完一个 4 波据点：A 被脚本杀了约 66 个敌人（含联机加强的额外敌人）

## 客户端被关住

- B 进入后同样开始（护盾升起），但它刷的怪被客户端删除（敌人以房主为准），删除不触发 `CALL_EnemyDestroyed` → 永远不完成
- 在 B 那份上调用 `StrongholdCompleted(true)`：同样的序列（`SpawnLoot`、收护盾），`Completed?` 变 true

## Hook 的两个规律

- 子类重写的函数（`WaveSpawner`/`EliteSpawner`/`MiniBoss` 都声明了 `CALL_PlayerOverlappedStart`）不会触发挂在父类上的 hook
- 回调顺序：外层函数的回调排在它内部调用的函数之后，看起来回调在函数体执行完之后

## 替身的重叠事件

- 分仇恨用的替身是 `CH_LimaCharacter_C`。实测：生成时就触发了脚下区域的 `RunProgressor`；放进 boss 区域推进球又触发一次
- `CapsuleComponent:SetGenerateOverlapEvents(false)` + `Mesh:SetGenerateOverlapEvents(false)` 后再放进去：不触发
