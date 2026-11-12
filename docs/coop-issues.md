# 联机问题清单（单人游戏假设在联机下会出错的地方）

2026-11-05 起。来源：UE4SS 对象转储里每个蓝图的局部变量 `CallFunc_<函数名>`（能看出蓝图调用了哪些函数）、`BndEvt__…BeginOverlap`（靠重叠触发的蓝图）、CXX 头文件、实测。
新发现的问题加在这里；做完的写清实测结果。

背景：每个玩家跑自己那份世界。房主的世界里有队友的"替身"（隐藏的 `CH_LimaCharacter_C`，给敌人瞄准用，`aggro.lua`），客户端的世界里有房主的"傀儡"（普通网格 Actor，不是角色）。所以凡是"玩家走进来就触发"的东西，在房主那边可能被替身触发，在客户端那边永远不会被房主触发。

## 严重（会卡关、把人关住、让另一个人的游戏停住）

| # | 问题 | 证据 | 方案 | 状态 |
|---|---|---|---|---|
| 1 | **暂停**：打开暂停菜单、终端（升级 / 难度 / 皮肤 / 邮件）、教学弹窗会暂停整个世界。房主一暂停，敌人全定住，队友那边也卡住 | `SetGamePaused` 被 19 个蓝图调用：`WBP_PauseMenu_Main`、`BP_Terminal`、`WBP_Terminal_Main`、`BFL_StandardFunctions`、`BP_CreateWidget`、`CH_LimaCharacter`、13 个 `WBP_TutorialFull_*` | 联机时原生 hook `GameplayStatics:SetGamePaused`，把参数改成 false（原生函数改参数生效，见 CLAUDE.md） | ✅ 0.7.0 `coopfixes.lua`。实测：房主调用暂停后 `IsGamePaused` 仍为 false |
| 2 | **区域封锁**：进入下一区域时上一区域被封上。一个人先走，另一个人在自己的世界里还能走，但在房主世界里，客户端的替身可能先触发封锁，把房主关在后面；两人进度也会分开 | `BP_Scenario_Master`：`RunProgressor` 重叠 → `ProgressScenario()` / `ProgressWall()` → `DisableAllRunActorsRecursive()`；`BP_TraversalBlocker`：重叠时把 `OtherActor` 和 `GetActorOfClass(...)` 比较后 `ActivateBlocker()` | 谁本人先进入新区域，其他人 3 秒后被传送到他身边（落地前悬停到脚下有地面，最多 25 秒），在自己的世界里正常推进、封锁；替身触发的不算 | ✅ 0.7.0 `regionsync.lua`。实测：B 进入 boss 区域 → A 3 秒后传送到 B 旁 150 处站稳 |
| 3 | **区域 / 据点 / 竞技场把客户端关在里面**：客户端那份世界里的任务 Actor 会自己刷怪（被客户端删掉），客户端那边的任务永远等不到击杀，门不开 | `BP_Stronghold_*`、`BP_Mission_WaveSpawner`（`NumEnemiesToKill`、`AllEnemiesSpawned`）、`BP_BossFightArena_Master`、`WBP_Notification_AreaCleared/AreaFailed` | 房主的据点 / 竞技场完成（`StrongholdCompleted`）时，客户端对同一个调用 `StrongholdCompleted(true)`；客户端先进入据点时（`CALL_PlayerOverlappedStart`），房主那份也开始 | ✅ 0.8.0 `mission.lua`（`MISSION` 30）。实测：B 的据点被关住 → A 打完 4 波 → B 50 ms 内完成、护盾收起、掉自己的奖励。"客户端带动房主开始"只测到消息和判断，房主那边实际开始没亲眼看到 |
| 4 | **替身误触发房主世界的东西**：电梯、传送器、撤离点、出界、发射台、商店格子、图纸拾取、腐化器、方尖碑、boss 竞技场、雾区切换 | 这些蓝图有 `BeginOverlap` 且转换成 `CH_LimaCharacter`：`BP_MainLift`、`BP_Teleporter`、`BP_StartingTeleporter`、`BP_Mission_Extraction`、`BP_OutOfBounds`、`BP_LaunchPad`、`BP_VerticalLaunchPad`、`BP_ShopUnit_Master/Reroll`、`BP_Schematic_Pickup_Master`、`BP_Interactable_Corruptor_Master`、`BP_Interactable_Obelisk_Master`、`BP_BossFightArena_Master`、`BP_Trigger_FogSwitcher`、`BP_Scenario_Master`、`BP_PlayerTrigger`、`BP_1473_Dialogue_Trigger`、`BP_Announcement_Tannoy_Voice`、`BP_Recycler` | 替身一律不产生重叠事件（胶囊体和网格 `SetGenerateOverlapEvents(false)`），碰撞保留 | ✅ 0.8.0 `aggro.lua`。实测：替身生成时就触发了脚下区域、放进 boss 推进球又触发；关掉后不再触发 |
| 5 | **加密区域**：用解密器解锁的区域只在解锁的人那边打开 | `WBP_EncryptedArea`、`BP_LootChest_Encrypted` | 不同步：加密宝箱重写了 `InteractObjectHold`（花解密器打开），交互同步本来就不重放它，每人用自己的解密器开自己的箱子。`WBP_EncryptedArea` 只是界面，没有 Actor 用它 | ✅ 保持个人（0.8.1 核对） |
| 11 | **区域之间的通行地形每个人随机不一样**：同一位置房主是一种地形、客户端是另一种，脚下的路不是同一条（传送后掉下去的真正原因） | `BP_TraversalArea_C.PickRandomInstance` 用 `Array_Random`（无种子）从数据表挑关卡；实测 6 段里 5 段不同 | 房主把每段选的关卡发给客户端（`TRAV` 29），客户端卸掉自己的、在同一位置 `LoadLevelInstance` 房主那份 | ✅ 0.7.0 `traversal.lua`。实测：客户端加入 5 秒内换掉 5 段，两边一致 |
| 6 | **传送器 / 地图连接点（滑索）解锁**：只在使用的人那边解锁；关内传送只传送自己 | `BP_Teleporter`（`HasAccess?`、`Cost`）、`BP_MapConnector`（`Unlocked?`、`RequiredGateLevel`） | 不同步：传送器短按打开地图、长按付费解锁（`InteractObjectQuick/Hold`，有 `Cost`），都是个人操作；传送到新区域后由区域同步把队友拉过去 | ✅ 保持个人（0.8.1 核对） |

| 13 | **朋友单独换关**：自己坐电梯 / 传送门 / 撤离去了别的关卡，房主不跟，两人停在不同关卡 | 房主换关时客户端会跟（3.7b），反过来没有 | 只有房主能带全队换关：队友在别的关卡（主菜单除外）超过 10 秒，房主把世界存档重发给他，他读回房主的关卡；刚加入或刚换关后 90 秒内不拉 | ✅ 0.8.1 `session.lua`。实测：B 自己去了中心关卡 → 被拉回 B05 |

| 14 | **房主先退出，客户端的联机不会结束**：朋友回主菜单后存档保护还开着，"继续"读到的是联机存档，局外收获也不带回 | 客户端只把房主从队友里移除（`dropPeer`），会话还在 | 客户端发现房主离开（`BYE` 或 45 秒超时）就自动结束联机并提示回主菜单 | ✅ 0.8.3。实测：A 离开 → B 自动结束、最后存一次联机存档 → 回主菜单后存档切回 `LimaSaveGame` 并执行带回 |

## 中等

| # | 问题 | 证据 | 方案 | 状态 |
|---|---|---|---|---|
| 7 | **慢动作类效果是全局的**：一个人触发会让他整个世界变慢 | `SetGlobalTimeDilation`：`CH_LimaCharacter`、`PC_LimaPlayerController` | 先查哪些情况触发；房主触发时敌人对队友也变慢 | ✅ 0.8.2 `coopfixes.lua`：联机时原生 hook `SetGlobalTimeDilation`，值固定为 1，并记录游戏想设的值（日志 `coop: global slow motion`），以后能看出是哪些情况触发的。没在游戏里触发过，所以没有实测记录 |
| 8 | **大量蓝图只认 0 号玩家**（房主本人）：监控摄像头、全局激光、boss 舱门、发射物等只针对房主 | `GetPlayerCharacter` 被 132 个蓝图使用（`BP_CCTV_Camera`、`BP_GlobalLaser_01a`、`BP_BossHatch`、`BP_EnemyShockwave_Master`……） | 敌人子弹已经按仇恨改向；其余按影响逐个看 | 部分：敌人的优化器（`CH_AI_Base:Optimiser` 按离 0 号玩家的距离设 `SignificanceInterval` / 组件更新间隔）实测不起作用：800 到 20 万距离的步兵，间隔全是 0。剩下只针对房主的敌方机关（冲击波 `BP_EnemyShockwave_Master`、全局激光、监控摄像头、boss 舱门）只会伤到 / 发现房主，对客户端只是更容易，记为已知限制 |
| 9 | **boss 竞技场**：入场过场不同步；朋友先进去时房主那边不会开始（替身不再触发） | `BP_BossFightArena_Master`（父类 AActor）、`BP_BossTeleporter`；入口重叠事件和据点同名 | 完成已由 `mission.lua` 同步（`StrongholdCompleted`）；开始和过场要等实际打到 boss 时观察：用 Biome_05 的存档把人放进竞技场中心，没有任何函数被调用（多半要先完成"摧毁尖塔"、经 boss 传送门进入） | 待实测 |
| 10 | 混乱碎片联机中拿到的可能带不回去 | 存档里没写 | 观察游戏何时保存 | 待查 |
| 12 | 队友傀儡上的流送源好像没让那一带提前加载：传送过去后地面过了 8 秒以上才出现 | 实测 | 查 `WorldPartitionStreamingSourceComponent` 还需要什么设置；现在靠悬停等待兜底 | ✅ 不是问题：远离玩家 12 万的地方本来就有地面（这一关的普通地形整关加载）；组件本身已启用，状态和玩家的一样。之前掉下去的真正原因是通行地形不同（#11，已修） |

| 15 | **撤离任务（插数据块、守点）**：客户端插了数据块、站在区域里，自己那边开始并完成；房主那边显示还没开始 | 2026-11-13 真实联机；调查见 `research/phase4-09-extraction.md` | 插数据块双向同步（`CubeOverlapped`）；每秒发"我在上传区里"，对方保持 `PlayerInZone`；房主失败按失败同步（以前会当成功）；客户端那份 `StopSpawner`（删它刷的敌人会崩） | ✅ 0.12.0。双开实测：谁在区域里两边都上传，都不在就都暂停，两边同时成功；房主失败 → 客户端也失败。真实关卡里的撤离任务还没测 |
| 16 | **手雷 / 技能看不到** | 用户报告 2026-11-13 | 先查投掷物、技能的类和发射函数 | 待做 |

## 已解决

- 客户端看不到 boss 血条 → 0.11.0 `bossbar.lua`（真正的 boss 战还没实测）
- 队友的子弹远处看不见（拖尾特效有距离剔除）→ 0.11.0
- 每次点加入都备份并切换存档槽，连不上也一样，失败的重试把备份挤满 → 0.10.0 连上才动存档
- 房主对每个 HELLO 都发一遍存档，客户端读两次世界 → 0.10.0 30 秒内只发一次
- 看不到队友的手、枪和子弹 → 0.9.0 `avatars.lua`（`research/phase4-08-avatars.md`）
- 房主的仇恨替身（以及客户端的化身）各自带一套 HUD 盖在自己的 HUD 上，拿不同的枪时本地 HUD 显示错 → 0.9.0 折叠化身的 `PlayerIcons`、`MissionHUD`
- 剧情 / 对话只有触发的人看到 → 0.6.0 `storysync.lua`
- 宝箱、开关、拉杆、方尖碑只在使用的人那边生效 → 0.3.0 `interact.lua`
- 敌人只追房主、只打房主 → 3.4b `aggro.lua`
- 场景破坏不同步 → 3.5 `destruction.lua`
- 客户端存档被联机覆盖 → 3.6 `saveguard.lua`
