# 合作规则（玩法设计决定）

2026-11-04 与用户确认。实现时以这里为准；改动要先和用户确认。

| 主题 | 决定 | 实现要点 |
|---|---|---|
| 时停 / 慢动作 / EMP 类全局效果 | **全员生效** | 房主执行 `PC.FreezeTime/ResumeTime`、`ABL_ActivateChronoHold?` 时广播给所有人；客户端施放时先发请求，由房主统一执行 |
| 玩家死亡 | **倒地 + 队友复活** | 新增"倒地"状态：生命归零时不结束这一局，改成倒地；队友靠近后长按交互键复活；全员倒地才算这一局失败。需要拦截单机的死亡流程（`BP_EndRun` / `RespawnPlayer` / `ShowRunDeathScreen?`） |
| 掉落 | **每人各得一份**（2026-11-05 用户选定，取代原来的"资源产出 ×2"） | 敌人在房主那边死亡时房主正常掉落；客户端的镜像敌人死亡时也按游戏自己的掉落规则在客户端世界里掉落（`DeathEvent(false)`），各捡各的。不再额外翻倍；如果以后觉得资源偏多或偏少，再调 |
| 背包 | **个人所有**（2026-11-05 用户选定，取代原来的"全队共享"：掉落已经是每人一份，共享背包会让东西成倍出现） | 每人用自己的背包（`InventorySlots`），不同步；不做房主仲裁 |
| 武器上的模组 | **个人所有** | 和背包一样，各管各的（`Weapon01Slots/Weapon02Slots`），不同步 |
| 局外成长 | **每人用自己的存档；联机中得到的局外成长带回自己的存档**（2026-11-05 用户选定"只带回局外成长"） | 每人带自己的永久升级和解锁进入房主的局；局内进度由房主说了算。客户端联机期间只写 `VBMP_client.sav`；离开联机回到主菜单时（或下次启动到主菜单时），把联机存档里的局外属性（Voidium、`UPG_*`、六项属性和 `*Ranks`、解锁、研究、皮肤、混沌任务、迭代纪录、日志邮件、教程提示、解密器、图纸）拼回真实存档，先自动备份；局内的武器、模组、背包、VoidCoins（信用币，游戏标注"死亡后删除"）、能力解锁恢复到加入前。解密器、图纸按游戏背包页的"死亡后保留"标注算局外，一起带回。实现见 `saveguard.lua` |

## 实现入口（build 23764881，CXXHeaderDump `CH_LimaCharacter_C`，未实测）

- **资源 ×2**：所有货币都经过 `AddCurrency(int32 AmountToAdd, Enum_PickupOrbType CurrencyType)`（货币类型 0–3）。房主在前置 hook 里把 `AmountToAdd` 翻倍（UE4SS 的 hook 参数支持 `:set()`）。相关的还有 `PickedUpCurrency`、`AddCurrencyEvent`、`SpawnMoneyOrb(Amount, Location)`、`PickupWeaponChip(Points)`，要用探针确认是否会被重复计算
- ~~共享背包~~（2026-11-05 取消，背包改为个人所有）。留作参考的入口：`AddToInventory`、`AddToInventoryIndex`，数据 `InventorySlots`、`Weapon01Slots/Weapon02Slots`
- **倒地 / 复活**：
  - 血量：`Health`、`MaxHealth`；受伤入口 `DealDamageToPlayer(double)`
  - 死亡流程：`HandleDeathUI`、`Death_DropArms`、`Save_PlayerDeath`、`RespawnPlayer`（`GM_LimaGameMode_C` 也有 `RespawnPlayer`）；死亡界面 `WBP_DeathScreen`
  - **游戏自带原地复活 `ReviveFromEntropy()`**，可以拿来做"被队友救起"
  - 方案：致命伤害时，把血量钳在 1，进入倒地状态（锁移动 `CinematicLock`、显示提示），不走死亡流程；队友在傀儡旁长按交互键复活（调用 `ReviveFromEntropy`）；全员倒地才走原来的死亡流程
- **时停全员生效**：`PC_LimaPlayerController_C.FreezeTime/ResumeTime`、`ABL_ActivateChronoHold?(bool, duration)`；`BPI_PauseFreeze` 的实现者（玩家、敌人、电梯、滑索）
