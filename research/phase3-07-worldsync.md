# Phase 3.6–3.7：客户端存档保护和世界同步

build 23764881，2026-11-05。单实例和双实例自测。

## 存档怎么写（3.6）

- **槽名**：`GI_LimaGameInstance_C.SlotName : FString`（CXX 转储 0x290），默认 `LimaSaveGame`，读档和存档都用它
- **同步存档**：`GI.SaveGameData(false)` → `GameplayStatics.SaveGameToSlot(SaveGame, "LimaSaveGame", 0)`
  - 在这个**原生**函数的前置 hook 里改槽名能生效：游戏真的写进了 `VBMP_redirect.sav`，`LimaSaveGame.sav` 时间戳不变
- **异步存档**：`GI.SaveGameData(true)` 是游戏平时用的方式
  - 文件照样被写了，但 `AsyncActionHandleSaveGame.AsyncSaveGameToSlot` 和 `SaveGameToSlot` 的 hook 都是 0 次
  - 拦不住，只能改 `GI.SlotName`
- **实现**：`saveguard.lua`
  - 客户端开始联机时，先把真实存档复制成 `VBMP_client.sav`，再把槽名改过去
  - 同步存档、删档的原生 hook 作为第二层
  - 离开联机后保持保护，直到回到主菜单
  - "回到主菜单"用 `GameplayStatics.GetCurrentLevelName(GI)` 判断。`FindFirstOf` 菜单类不行：上次去菜单留下的对象换关后还能找到
- **验证**：
  - 客户端身份下同步、异步存档都进了 `VBMP_client.sav`
  - 回主菜单后 2 秒内换回 `LimaSaveGame`，比第一次检查还早
  - 继续游戏后正常写回真实存档

## 世界由存档决定（3.7 的前提）

- **读档时只重建，不重新分配**：Continue 读档时 GameMode 调用 `GenerateWorld`，不调用 `AssignScenarios`（VBTrace 事件日志）
- **同一存档读两次结果一样**：子关卡资源名和位置完全相同（`wg_snap` 对比）
  - 只有漂浮岩石等装饰实例因流送范围不同而不同
  - GameMode 的 `ChosenRed/Orange/BossScenario` 读档后都是 nil
  - 存档里的 `RunActors` 是空的；`ExcludedLevels` 有 3 项
- **两个进程读同一个存档**：可破坏物名字和坐标完全一致（3.5 双实例）
- **换槽读档的操作**：在主菜单设 `GI.SlotName = X`，`LoadGameData(false)`，再按 Continue，就会读进 X 的世界（实测换到 Biome_04 的存档）

## 实现：`worldsync.lua`，消息 `WORLD_SAVE = 19 "<I4I4I4s2"`

- **房主**：收到客户端 HELLO 时先 `SaveGameData(false)`，再把槽文件按 30000 字节一块发出去
  - 本地文件传输按 `<s2` 分帧，单帧不超过 65535 字节
- **客户端**：
  - 拼完后写进 `VBMP_client.sav`
  - 打开主菜单，在屏幕上的 `WBP_PlayMenu_C` 按 Continue
  - 关卡名不再是菜单、并且有控制器时，就算完成
- **双实例验证**：
  - B 先读另一个存档进 Biome_04，A 在 Biome_05
  - B 加入后 5 秒内进入 Biome_05，物体名字和坐标与 A 一致，联机保持连接
  - 读档后 A 打碎地砖，B 同步碎掉

## 顺带修掉的问题

- **会话时钟**：用的是 `GameplayStatics.GetRealTimeSeconds(world)`，它从**当前世界**启动开始计时，换关卡就倒退到 0 附近
  - 读档后发送计时器累加了几百秒的负数，客户端停止发送，几秒后被超时踢掉
  - 改为单调时钟，只累加正的时间差
- **旧对象**：换关卡后 `FindFirstOf("PC_LimaPlayerController_C")` 可能还是上一个世界的控制器
  - 改用 `GameplayStatics.GetPlayerController(GI, 0)`（`aggro.localController`）
  - main.lua 和 hud.lua 每次重新取本地玩家

## 3.7c：只同步布局（`gvas.lua`）

GVAS 格式（UE 5.7.4，实测本游戏存档）：

1. 文件头：`GVAS`、存档版本 3、UE4/UE5 包版本、引擎版本（含分支字符串）、自定义版本表（每项 20 字节）、存档类名，再加 1 个 `uint8`（0）
2. 顶层属性标签（UE 5.4 以后统一的格式）：名字、类型名树（每个节点是名字 + 子节点数）、`int32` 大小、`uint8` 标志，然后是 `size` 字节的值
   - 标志 1：后面跟 `int32` 数组下标
   - 标志 2：后面跟 16 字节 GUID
   - 布尔值的大小是 0，值放在标志位 `0x10` 里
3. 列表以 `None` 结束，后面保留原文件尾

拼接方法：以客户端自己的存档为底，删掉布局属性，再换成房主存档里的同名属性。房主存档里没有的布局属性也从底稿里删掉，因为取默认值的属性不会写进存档。

实测：拼接结果 Python 和游戏都能读；B 用另一个存档加入，进入房主的 Biome_05，保留了自己的货币（0，房主是 759）。

## 缺口

- （已由 3.7c 修复）**客户端带的是房主的角色状态**（武器、模组、背包、局外成长），只存在 `VBMP_client.sav` 里，真实存档不受影响
  - 这和 `coop-rules.md` 的"模组归个人、局外成长各用各的"不一致
  - 下一步应该只合并布局字段（关卡、生物群系、层级、起点、`ExcludedLevels`、`DestroyedActors`、`SwitchedActors`、`ObjectSaveData` 等）
- **只在加入时同步一次**：房主换关卡、换生物群系后，客户端不会跟着重新读档
- **起点不对**：客户端出生在房主上次存档的起点，不是房主当前的位置
- **还没在两台不同电脑上验证过**：存档在不同电脑上读出的世界是否一样，还没验证（预期一样，因为世界只由存档决定）
