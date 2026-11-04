# 合作规则（玩法设计决定）

2026-11-04 与用户确认。实现时以这里为准；改动要先和用户确认。

| 主题 | 决定 | 实现要点 |
|---|---|---|
| 时停 / 慢动作 / EMP 类全局效果 | **全员生效** | 房主执行 `PC.FreezeTime/ResumeTime`、`ABL_ActivateChronoHold?` 时广播给所有人；客户端施放时先发请求，由房主统一执行 |
| 玩家死亡 | **倒地 + 队友复活** | 新增"倒地"状态：生命归零时不结束这一局，改成倒地；队友靠近后长按交互键复活；全员倒地才算这一局失败。需要拦截单机的死亡流程（`BP_EndRun` / `RespawnPlayer` / `ShowRunDeathScreen?`） |
| 掉落 | **资源产出 ×2** | 房主生成掉落时数量翻倍（金币、Voidium、弹药等资源类）。模组掉落是否也翻倍待定 |
| 背包 | **全队共享** | 背包（`InventorySlots`）只有一份，由房主保管；谁捡到都进共享背包，所有人都能看到、都能取 |
| 武器上的模组 | **个人所有** | 从共享背包拖到自己武器上（`Weapon01Slots/Weapon02Slots`）后归自己；拖回背包就重新变成共享的 |
| 局外成长 | **暂定：每人用自己的存档**（用户还没明确确认，2026-11-04 先按此设计） | 每人带自己的永久升级（`UPG_*`）和解锁进入房主的局；局内进度（关卡、生态区、场景选择）由房主说了算；客户端在联机期间不写局内存档，局外的收获（Voidium 等）回到自己的存档 |

## 实现入口（build 23764881，CXXHeaderDump `CH_LimaCharacter_C`，未实测）

- **资源 ×2**：所有货币都经过 `AddCurrency(int32 AmountToAdd, Enum_PickupOrbType CurrencyType)`（货币类型 0–3）。房主在前置 hook 里把 `AmountToAdd` 翻倍（UE4SS 的 hook 参数支持 `:set()`）。相关的还有 `PickedUpCurrency`、`AddCurrencyEvent`、`SpawnMoneyOrb(Amount, Location)`、`PickupWeaponChip(Points)`，要用探针确认是否会被重复计算
- **共享背包 / 个人武器**：
  - 加入背包：`AddToInventory(UPDA_MasterDetails_C*, Enum_InventoryType)`、`CreateStack_Inventory`、`AddToStack_Inventory`、`FindExistingStack_Inventory`
  - 拖拽：`AddToInventoryIndex(DroppedInventory, DraggedInformation, DroppedIndex, DraggedInventory, DraggedIndex, …)`。参数里有拖出和放入的背包类型，"背包 ↔ 武器"的边界就在这里：拖进武器 = 从共享背包取走，拖回背包 = 放回共享背包
  - 数据：`InventorySlots`（背包）、`Weapon01Slots/Weapon02Slots`（武器）、`BodyMods`、`RelicSlots`
- **倒地 / 复活**：
  - 血量：`Health`、`MaxHealth`；受伤入口 `DealDamageToPlayer(double)`
  - 死亡流程：`HandleDeathUI`、`Death_DropArms`、`Save_PlayerDeath`、`RespawnPlayer`（`GM_LimaGameMode_C` 也有 `RespawnPlayer`）；死亡界面 `WBP_DeathScreen`
  - **游戏自带原地复活 `ReviveFromEntropy()`**，可以拿来做"被队友救起"
  - 方案：致命伤害时，把血量钳在 1，进入倒地状态（锁移动 `CinematicLock`、显示提示），不走死亡流程；队友在傀儡旁长按交互键复活（调用 `ReviveFromEntropy`）；全员倒地才走原来的死亡流程
- **时停全员生效**：`PC_LimaPlayerController_C.FreezeTime/ResumeTime`、`ABL_ActivateChronoHold?(bool, duration)`；`BPI_PauseFreeze` 的实现者（玩家、敌人、电梯、滑索）
