# VBTools / 01 — 难度、无限迭代、模组与复发器

- 日期：2026-11-04，build `23764881`
- 来源：UE4SS CXXHeaderDump（`BP_SaveGame_Lima`、`WBP_Difficulty_Main`、`AC_Mod_Master`、`BFL_StandardFunctions`、`CH_LimaCharacter`、`BP_Weapon_Base`）和资源清单

## 存档

- 只有一个存档文件：`%LOCALAPPDATA%\VOIDBREAKER\Saved\SaveGames\LimaSaveGame.sav`（类 `BP_SaveGame_Lima_C`）。另有设置存档 `Settings.sav`
- 同时开着 Steam 云同步（`C:\D\userdata\<id>\2615540\`）
- **局内进度和局外成长在同一个对象里**：
  - 局内：`IsInActiveRun?`、`HasSavedRunProgress?`、`Weapon01Slots/02Slots`、`Weapon01Mods/02Mods`、`BodyMods`、`InventorySlots`、`*ProjectileSlot`、`CurrentBiome`、`CurrentBiomeTier`、`OverallTier`、`CurrentSavedLevel`、`PlayerStartTag`、`DestroyedActors`、`ObjectSaveData`、`PlayerHealth`、`CurrentLoops`、`CurrentSubLoops` …
  - 局外：`UPG_*`（三十多项永久升级）、`Vitality/Ergonomics/Capacity/Endurance/Cognition/Exponent` 及各自的 `*Ranks`、`Voidium`、`Rank`、`Unlocked*`、`ResearchedSchematics`、`UnlockedSkins`、`MaxIterationReachedOn*`、`ChaosMission*`、`ChaosFragments` …
- 运行时的存档对象：`GI_LimaGameInstance_C.LatestSaveGame`；GameMode 里也有一份引用 `As BP Save Game Lima`

## 难度

- 主难度 `MainDifficultySetting`（int）：普通 / 困难 / 疯狂。界面 `WBP_Difficulty_Main` 上有 `WBP_DifficultyButton_Normal/Hard/Insanity`，困难和疯狂需要先解锁（`HardUnlocked?`、`InsanityUnlocked?`）。从大厅的难度终端 `BP_Terminal_Difficulty` 进入
- **"无限模式" = 迭代（Iteration / Loop）**：打通一轮后进入更高的迭代继续打，存档记录 `CurrentLoops`、`CurrentSubLoops`，每个难度各有最高纪录 `MaxIterationReachedOnNormal/Hard/Insanity`。另有逻辑节点 `BP_Logic_Check_Iteration`
- **混沌修饰符**（类似"热度"）：18 个开关 `DIFF_*`，各自有 `ChaosRating` 分值（`PDA_DifficultyModifier`），合计成 `ChaosRating`：
  SilentNight、CreditSuspension、Inflation、Frenzy、AnomalySpike、AnomalyFault、UnluckyDay、ApexSurge、EliteSurge、StackThrottle、**RepeaterCap**（限制复发器）、DeathLock、Reinforcements、Vulnerable、Lifeline、SlimPickings、Empowered、FastRecovery
- 混沌任务：`ChaosMissionAct1/Act2`（bool 数组）、`ChaosMissionNumber`、`ChaosMissionAchieved_Act1/2`
- 每个生态区还有难度曲线表 `DT_B0x_DifficultyCurve`

## 模组和复发器

- 武器插槽是一个网格：`CH_LimaCharacter_C.Weapon01Slots/Weapon02Slots : TArray<FSTR_StackInformation>`
  - 结构字段：`MasterDetails`（模组数据资产 `UPDA_MasterDetails_C`）、`InventoryType`、`Filled?`、`SlotState`、`Frequency`、`Column`、`Row`、`IsRepeaterHeader?`、`IsChassisMod?`
- 装上之后变成组件：`BP_Weapon_Base_C.CurrentlyAttachedMods : TArray<UAC_Mod_Master_C*>`
  - `UAC_Mod_Master_C` 有 `ModDetails`、`ExecutionSlotIndex`、**`ExecutionFrequency`**
  - `CalculateExecutions(Weapon)` 负责算出执行次数，各个 `ApplyMod*Effects` 再按次数生效
  - 通用函数 `BFL_StandardFunctions.FrequencyCalculator(FrequencyIn, BaseValue, ValueToAddForEachRepetition)`
- 复发器模组（`Blueprints/Data/Mods/Weapons/`）：`DA_W_RowRepeater`、`DA_W_ColumnRepeater`、`DA_W_Up/Down/Left/RightRepeaterMax`；复制器：`DA_W_*SlotDuplicator`、`DA_W_LiveDuplicator`、`DA_W_DuplicationBurst`、`DA_W_EchoShot`；清单表 `DT_FullModsList_RepeaterMods`
- 相同模组本身就会叠加：`CalculateModDataRecurrance(AttachedMods, QueryModData) -> Frequency`
- 重算入口：`CH_LimaCharacter_C.RecalculateMods(bool RecalculateAll?)`

## VBTools 的实现（v1）

- **存档槽**：`tools/remote/save_slots.ps1` + `VBSaves.bat`（gaming PC 的 `C:\Users\User\vbmp\`）。整个存档文件做快照和恢复；恢复前会自动备份当前存档，游戏运行时拒绝恢复
  - 限制：恢复时局外成长也会回到快照时的样子。之后可以在游戏内用 `LatestSaveGame` 只换局内字段，做成"保留局外成长"的版本
- **三合一**：Ctrl+F6。在同一把武器上找到 3 个相同的模组（跳过复发器头和底盘模组），清空其中 2 个插槽，剩下那个记一次 +1 执行次数，然后 `RecalculateMods(true)`
  - 加成在 `AC_Mod_Master_C:CalculateExecutions` 的后置 hook 里加上，紧跟在游戏自己的计算之后
  - 加成按"武器 + 模组资产"记在 `%LOCALAPPDATA%\VOIDBREAKER\Saved\VBTools_fusion.txt`，绑定存档的 `RunNumber`，开新局时自动清零
  - Ctrl+F7 打印每个已装模组的执行次数和加成，用于验证
- 未验证的假设（等测试）：
  1. UE4SS Lua 改 `TArray` 里结构体的字段，会直接写回游戏内存
  2. 这个 UE4SS 版本的 Blueprint 函数支持后置 hook（不支持就自动退回延迟加成，F7 会显示 pre/post 次数）
  3. 被清空的插槽在背包界面里显示为空，存档后也保持为空
