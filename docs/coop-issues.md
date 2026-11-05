# 联机问题清单（单人游戏假设在联机下会出错的地方）

2026-11-05 起。来源：UE4SS 对象转储里每个蓝图的局部变量 `CallFunc_<函数名>`（能看出蓝图调用了哪些函数）、`BndEvt__…BeginOverlap`（靠重叠触发的蓝图）、CXX 头文件、实测。
新发现的问题加在这里；做完的写清实测结果。

背景：每个玩家跑自己那份世界。房主的世界里有队友的"替身"（隐藏的 `CH_LimaCharacter_C`，给敌人瞄准用，`aggro.lua`），客户端的世界里有房主的"傀儡"（普通网格 Actor，不是角色）。所以凡是"玩家走进来就触发"的东西，在房主那边可能被替身触发，在客户端那边永远不会被房主触发。

## 严重（会卡关、把人关住、让另一个人的游戏停住）

| # | 问题 | 证据 | 方案 | 状态 |
|---|---|---|---|---|
| 1 | **暂停**：打开暂停菜单、终端（升级 / 难度 / 皮肤 / 邮件）、教学弹窗会暂停整个世界。房主一暂停，敌人全定住，队友那边也卡住 | `SetGamePaused` 被 19 个蓝图调用：`WBP_PauseMenu_Main`、`BP_Terminal`、`WBP_Terminal_Main`、`BFL_StandardFunctions`、`BP_CreateWidget`、`CH_LimaCharacter`、13 个 `WBP_TutorialFull_*` | 联机时原生 hook `GameplayStatics:SetGamePaused`，把参数改成 false（原生函数改参数生效，见 CLAUDE.md） | ✅ 0.7.0 `coopfixes.lua`。实测：房主调用暂停后 `IsGamePaused` 仍为 false |
| 2 | **区域封锁**：进入下一区域时上一区域被封上。一个人先走，另一个人在自己的世界里还能走，但在房主世界里，客户端的替身可能先触发封锁，把房主关在后面；两人进度也会分开 | `BP_Scenario_Master`：`RunProgressor` 重叠 → `ProgressScenario()` / `ProgressWall()` → `DisableAllRunActorsRecursive()`；`BP_TraversalBlocker`：重叠时把 `OtherActor` 和 `GetActorOfClass(...)` 比较后 `ActivateBlocker()` | 谁本人先进入新区域，其他人 3 秒后被传送到他身边（落地前悬停到脚下有地面，最多 25 秒），在自己的世界里正常推进、封锁；替身触发的不算 | ✅ 0.7.0 `regionsync.lua`。实测：B 进入 boss 区域 → A 3 秒后传送到 B 旁 150 处站稳 |
| 3 | **区域 / 据点 / 竞技场把客户端关在里面**：客户端那份世界里的任务 Actor 会自己刷怪（被客户端删掉），客户端那边的任务永远等不到击杀，门不开 | `BP_Stronghold_*`、`BP_Mission_WaveSpawner`（`NumEnemiesToKill`、`AllEnemiesSpawned`）、`BP_BossFightArena_Master`、`WBP_Notification_AreaCleared/AreaFailed` | 房主的任务完成时，客户端对同一个任务 Actor 重放"完成"；需要先查任务完成走哪个函数 | 待查 |
| 4 | **替身误触发房主世界的东西**：电梯、传送器、撤离点、出界、发射台、商店格子、图纸拾取、腐化器、方尖碑、boss 竞技场、雾区切换 | 这些蓝图有 `BeginOverlap` 且转换成 `CH_LimaCharacter`：`BP_MainLift`、`BP_Teleporter`、`BP_StartingTeleporter`、`BP_Mission_Extraction`、`BP_OutOfBounds`、`BP_LaunchPad`、`BP_VerticalLaunchPad`、`BP_ShopUnit_Master/Reroll`、`BP_Schematic_Pickup_Master`、`BP_Interactable_Corruptor_Master`、`BP_Interactable_Obelisk_Master`、`BP_BossFightArena_Master`、`BP_Trigger_FogSwitcher`、`BP_Scenario_Master`、`BP_PlayerTrigger`、`BP_1473_Dialogue_Trigger`、`BP_Announcement_Tannoy_Voice`、`BP_Recycler` | 先实测替身到底会不会触发；会的话逐个决定：boss 竞技场、剧情触发可以保留（相当于队友进来了），电梯 / 传送 / 撤离 / 商店 / 拾取 / 发射台要挡掉 | 待测 |
| 5 | **加密区域**：用解密器解锁的区域只在解锁的人那边打开 | `WBP_EncryptedArea`、`BP_LootChest_Encrypted` | 和宝箱一样同步"解锁" | 待查 |
| 11 | **区域之间的通行地形每个人随机不一样**：同一位置房主是一种地形、客户端是另一种，脚下的路不是同一条（传送后掉下去的真正原因） | `BP_TraversalArea_C.PickRandomInstance` 用 `Array_Random`（无种子）从数据表挑关卡；实测 6 段里 5 段不同 | 房主把每段选的关卡发给客户端（`TRAV` 29），客户端卸掉自己的、在同一位置 `LoadLevelInstance` 房主那份 | ✅ 0.7.0 `traversal.lua`。实测：客户端加入 5 秒内换掉 5 段，两边一致 |
| 6 | **传送器 / 地图连接点（滑索）解锁**：只在使用的人那边解锁；关内传送只传送自己 | `BP_Teleporter`（`HasAccess?`、`Cost`）、`BP_MapConnector`（`Unlocked?`、`RequiredGateLevel`） | 解锁要同步；关内传送后队友是否跟随要定规则 | 待查 |

## 中等

| # | 问题 | 证据 | 方案 | 状态 |
|---|---|---|---|---|
| 7 | **慢动作类效果是全局的**：一个人触发会让他整个世界变慢 | `SetGlobalTimeDilation`：`CH_LimaCharacter`、`PC_LimaPlayerController` | 先查哪些情况触发；房主触发时敌人对队友也变慢 | 待查 |
| 8 | **大量蓝图只认 0 号玩家**（房主本人）：监控摄像头、全局激光、boss 舱门、发射物等只针对房主 | `GetPlayerCharacter` 被 132 个蓝图使用（`BP_CCTV_Camera`、`BP_GlobalLaser_01a`、`BP_BossHatch`、`BP_EnemyShockwave_Master`……） | 敌人子弹已经按仇恨改向；其余按影响逐个看 | 待查 |
| 9 | **boss 入场过场**不同步 | `BP_BossFightArena_Master`、`BP_BossTeleporter` 自己放序列 | 和剧情同步一样重放 | 待做 |
| 10 | 混乱碎片联机中拿到的可能带不回去 | 存档里没写 | 观察游戏何时保存 | 待查 |
| 12 | 队友傀儡上的流送源好像没让那一带提前加载：传送过去后地面过了 8 秒以上才出现 | 实测 | 查 `WorldPartitionStreamingSourceComponent` 还需要什么设置；现在靠悬停等待兜底 | 待查 |

## 已解决

- 剧情 / 对话只有触发的人看到 → 0.6.0 `storysync.lua`
- 宝箱、开关、拉杆、方尖碑只在使用的人那边生效 → 0.3.0 `interact.lua`
- 敌人只追房主、只打房主 → 3.4b `aggro.lua`
- 场景破坏不同步 → 3.5 `destruction.lua`
- 客户端存档被联机覆盖 → 3.6 `saveguard.lua`
