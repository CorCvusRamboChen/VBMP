# Phase 0 / 02 — 资源清单调查

- 日期：2026-11-04
- 游戏 build：`23764881`（1.0 之前的抢先体验版）
- 方法：`research/scripts/vb_filelist.ps1` 用 AES 密钥只解密 pak 的完整目录索引和 IoStore 的目录索引，只读文件路径，不读任何资源内容
- 原始清单：`research/_local/filelist-23764881.tsv`（33,946 行，**不进仓库**，已写进 `.gitignore`）
- 顺带确认：IoStore 容器用的是同一把 AES 密钥

## 总览

| 容器 | 文件数 |
|---|---|
| `VOIDBREAKER-Windows.pak`（着色器、插件描述、配置、图片等非资源文件） | 4,707 |
| `VOIDBREAKER-Windows.utoc`（游戏资源 .uasset/.umap/.ubulk） | 29,236 |

游戏自己的内容都在 `/VOIDBREAKER/Content/ProjectLima/`，共 14,708 个文件。其余是商城素材包（城市、植被、特效包等）、FMOD 音频和 MetaHumans。

## 结论 1：玩家只有第一人称手臂 → 远端玩家需要另找模型

- 玩家角色：`/VOIDBREAKER/Content/FirstPerson/Blueprints/CH_LimaCharacter`。由 UE 第一人称模板演变而来，**是一个 1.16 MB 的大蓝图**
- 模型和动画只有手臂：`Meshes/MergedGeometry/Merged_Arms/SM_Arms`、`SM_Gloves`、`Animations/ABP_FPS_Arms`、`AS_LimaFPS_*`、`AM_Arms_*`（各武器的换弹/检视动作）
- **没有玩家的第三人称身体**
- 远端玩家的模型可选方案：
  1. 借用游戏里现成的人形模型：`MetaHumans/NPC_01`、`NPC_02` 各有完整的 Body（目前用于死亡 NPC 和过场动画），但没有走跑动画
  2. 借用某个人形敌人的骨骼模型和动画
  3. 自己做一个模型和动画，打成独立的 pak mod（最干净，工作量最大）
  - 原型阶段先用方案 1 或 2，或者干脆用一个胶囊体加手臂模型

## 结论 2：破坏系统是 Chaos Geometry Collection → 同步"破坏事件"，不同步碎片

- 相关资源大约 2,000 个：`Geometry_Collections/`（415）、`Destructibles/`（562）、`Meshes/FracturedMeshes/`（1,008）、`Blueprints/DestructibleCollections/`（110）
- 核心蓝图：
  - `Blueprints/Chaos/BP_BuildingDestructionManager`：建筑破坏总管
  - `Blueprints/Components/BP_ChaosPoolManager`：碎片池，说明碎片会被回收，是临时存在的
  - `Blueprints/Chaos/Fields/FS_ChaosField_Projectile_Master`、`FS_ChaosField_Continuous_Dash`、`FS_MasterField_Chaos`：子弹、冲刺等力场
  - `Blueprints/Chaos/DestructibleItems/*`：可破坏物的各种母版（道具、建筑模块、玻璃、可投掷物、预破碎件）
  - `Blueprints/Gameplay/Logic/BP_AddToDestroyedActors`：**游戏自己维护了一个"已被摧毁的 Actor"列表**，很可能用于存档或防止重新生成
  - 接口：`BPI_DestructionInterface`、`BPI_DestructionProp`、`BPI_DetonationInterface`
- 主程序里大量出现的 GeometryScript/DynamicMesh 只是引擎代码；游戏资源里没有用它做破坏的迹象，**之前"布尔切割"的猜想基本排除**
- 同步思路：
  - 房主广播"哪个可破坏 Actor 在哪里、被什么力场、以多大强度击中"
  - 客户端在本地施加同样的力场，碎片的具体样子允许不同
  - 对玩法有影响的状态（哪些墙已经没了、哪些物件已摧毁）跟随 `DestroyedActors` 列表做权威同步
  - 中途加入时，直接下发这个列表

## 结论 3：关卡不是逐格随机生成，而是"手工模块 + 随机选择开关"

- 主关卡用 World Partition：`Levels/MainLevels/JointBiome/LV_P_MainLevel`（1.7 MB），另有 B02–B05 和 EscapeLevel。148 张主地图，3,686 个 `_Generated_` 流送单元
- 每个生态区（Biome_01–05）都有手工制作的模块：`CombatArenas`、`ChestAreas`、`Shop`、`Obelisk`、`Corruptor`、`Uncharted*`、`Boss`，以及 `TransitionRegions`
- 随机性来自这些蓝图：
  - `Blueprints/Procedurals/BP_ScenarioAssigner`、`BP_DataLayerSwitcher`、`BP_Stronghold_VarationSwitcher`、`BP_StartingPoint`
  - `Blueprints/Gameplay/Logic/BP_Logic_DataLayerLoader`、`BP_Logic_RemoveLevelPool`、`BP_Logic_Chance`
  - `Blueprints/Gameplay/ChanceSpawners/*`、`Procedurals/Spawners/PCG_RoamingEnemySpawns`（唯一一个 PCG 资源）
  - `Voxel/BP_Scenario_*`：名字叫 Voxel，实际是关卡场景配置（Red/Green/Orange/City/Boss）
- 同步思路：
  - **不要指望同步随机种子**。蓝图的随机节点大多直接用全局随机数，很难保证两边一致
  - 改成房主做出选择（激活哪些 Data Layer、分配哪个 Scenario、Chance 的结果），再把选择结果下发给客户端，客户端按结果执行
  - 要在 UE4SS 里 hook 这几个蓝图的关键函数

## 其他对联机有用的发现

- **几乎所有玩法逻辑都是蓝图**：GameMode `GM_LimaGameMode`、控制器 `PC_LimaPlayerController`、`PS_LimaPlayerState`、`GI_LimaGameInstance`、存档 `BP_SaveGame_Lima`，以及武器、敌人 AI、破坏
  - 蓝图函数和变量都能通过 UE 反射看到和调用，所以 UE4SS 可以直接 hook（`ProcessEvent` / Kismet 函数），不用大量反汇编 C++
  - 这是很大的利好，也是 Multivoid 走过的路
- 输入用 Enhanced Input（`FirstPerson/Input/IA_*`、`IMC_*`），共 30 多个动作：移动、射击、冲刺、钩爪、技能、手雷、近战、无人机等
- 敌人：`Blueprints/Characters/Enemies/CH_AI_*`，40 多种，含 5 个 Boss；共同父类是 `CH_AI_Base` / `CH_AI_Enemy`
- 武器：`Blueprints/Weapons/BP_Weapon_Base` 和 6 把枪（Pistol/SMG/AssaultRifle/Shotgun/Marksman/Sniper），改装件在 `Blueprints/Mods`（240 个）
- 对象池：`BP_ProjectilePoolManager`、`BP_EnemyProjectilePool_Manager`、`BP_ChaosPoolManager`。同步时要注意池化对象会被复用，Actor 不能当作长期身份
- 插件里有商城插件 **SteamCore**（蓝图版 Steam API），说明游戏已经初始化了 Steam。我们的 mod 可以直接调用 `steam_api64` 的大厅和 P2P 网络
- 其他插件：AimAssistSystem、RecoilAnimation、AsyncLoadingScreen、Tether 等，对联机影响不大

## 对原计划的修正

1. Phase 1 的目标改成：**在房主的世界里生成一个"远端玩家傀儡"**，用 MetaHuman NPC 模型或胶囊体，位置由网络数据驱动。不要复制 `CH_LimaCharacter`，它是 1 MB 的单机大蓝图，内部到处默认自己是唯一的玩家
2. 关卡同步从"同步种子"改为"同步房主的选择"
3. 破坏同步优先级：先同步 `DestroyedActors` 级别的状态（玩法一致），再同步力场事件（视觉近似）
4. 仍然待确认：**确切的 UE 版本**、蓝图类的完整函数和变量签名（需要 UE4SS 的 CXXHeaderDump / UHT 头文件和 `.usmap`）

## 下一步

- 等 1.0 更新后：重跑 `vb_probe.ps1` 和 `vb_aeskey.ps1`（看指纹）以及 `vb_filelist.ps1`，比较清单差异
- 装 UE4SS（需要你在 gaming PC 前启动一次游戏）→ 拿到引擎版本、对象转储、`.usmap`
- 有了 `.usmap` 后，用 FModel 看 `CH_LimaCharacter`、`GM_LimaGameMode`、`BP_BuildingDestructionManager`、`BP_ScenarioAssigner` 的变量和函数
