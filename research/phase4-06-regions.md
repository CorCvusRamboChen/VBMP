# Phase 4.6 — 区域推进、通行地形、暂停

- 日期：2026-11-05，build 26439385（Biome_05 的存档）
- 来源：UE4SS 对象转储（`CallFunc_*` 局部变量、`BndEvt_*` 事件）、CXX 头文件、双实例实测

## 区域推进（BP_Scenario_Master）

- 一局由一串地图区域组成：`/Game/ProjectLima/Voxel/BP_Scenario_Master` 的子类 `BP_Scenario_Red_C`、`_Orange_C`、`_Boss_C`。Biome_05 有 17 个
- 每个区域有一个很大的 `RunProgressor`（`SphereComponent`，boss 区域半径约 11377）
- 角色进入它：`BndEvt__BP_Scenario_Master_RunProgressor_K2Node_ComponentBoundEvent_1_ComponentBeginOverlapSignature__DelegateSignature(OverlappedComponent, OtherActor, ...)`，随后 `ProgressWall()`、`ProgressScenario()`（实测 hook 都看到，`OtherActor` 是进入的角色）
- 传送进球体也会触发这个重叠事件
- 区域分配（`AssignedLevelString`，如 `LV_B05_BT_SUB_15`）两边一致（来自存档）
- `BP_TraversalBlocker`（通行封锁）：重叠时 `OtherActor == GetActorOfClass(...)` 才 `ActivateBlocker()`；这次没观察到它触发

## 通行地形（BP_TraversalArea）

- 区域之间的连接地形是 `BP_TraversalArea_C`，`BeginPlay` 时 `PickRandomInstance(out ChosenLevel)` 用 `Array_Random`（无种子）从数据表挑一个关卡，`LevelInstance : ULevelStreamingDynamic` 加载（`PackageNameToLoad` 如 `/Game/ProjectLima/Levels/TransitionRegions/B05/LV_TRS_B05_01`..`04`）
- **每个游戏进程挑的不一样**：双实例 6 段里 5 段不同。房主传送到客户端站的地方会掉下去
- 换成房主那份（实测可行）：旧的 `SetShouldBeVisible(false)`、`SetShouldBeLoaded(false)`、`SetIsRequestingUnloadAndRemoval(true)`；`LevelStreamingDynamic.LoadLevelInstance(区域Actor, 包名, 旧的 LevelTransform.Translation, 区域旋转, out bOutSuccess, "", nil, false)` 返回新的流送对象，`bOutSuccess` 为 true

## 传送落地

- 刚传送到远处时那里可能还没流送进来：一次实测 2 秒掉了 5000，然后游戏的坠落保护把人送回原处
- 做法：传送后 `CharacterMovement.GravityScale = 0`、`Velocity = 0` 悬停，每 0.25 秒 `KismetSystemLibrary.LineTraceSingle(..., TraceChannel 0, ...)` 向下 3000 检测（返回值 bool 能拿到，命中结构体拿不到），命中再恢复重力（原值 2.65）
- 给客户端傀儡加的 `WorldPartitionStreamingSourceComponent` 是否生效没确认：有一次地面过了 8 秒以上才出现

## 暂停

- `SetGamePaused` 被 19 个蓝图调用（暂停菜单、终端、教学弹窗等），没有蓝图用 `PlayerController.SetPause`
- 联机时在原生 hook 里把 `bPaused` 改成 false：实测房主调用后 `IsGamePaused` 仍为 false
