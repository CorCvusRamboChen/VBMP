# Phase 4-08：队友的手、枪和子弹（0.9.0）

2026-11-12，build 26439385。双实例自测（gaming PC，A 房主、B 客户端，本机文件通道）。代码 `src/lua/VBMP/Scripts/avatars.lua`，消息 `PLAYER_GEAR` 31（`<s2`，武器数据资源路径）、`PLAYER_FIRE` 32（`<fffff`，镜头位置 + yaw + pitch）。

## 问题

之前队友只是一个人偶傀儡（普通网格 Actor），看不到手、枪，也看不到他开火。

## 做法

- **化身**：一个不附身的 `CH_LimaCharacter_C`。
  - 房主那边直接用 `aggro.lua` 的替身（本来就是隐藏的 `CH_LimaCharacter_C`），`aggro.externallyMoved = true`，由 avatars 每帧移动，不再 10 Hz 跳。
  - 客户端那边自己生成一个：不受伤、GodMode、无碰撞、无重叠、关 tick、移动模式 0。
- **手**：`FirstPersonArms`（SK_RashguardSleevesA）和 `SK_Gloves2B` 本来 `bOnlyOwnerSee = true`，改成 `SetOnlyOwnerSee(false)` + `SetVisibility(true)`，就能从外面看到。`FirstPersonCamera.bUsePawnControlRotation = false`，再每帧设相对 pitch，手和枪跟着抬头低头。
- **枪**：`GiveWeapons(UPDA_WeaponBase_C, nil)`。枪是子 Actor `PrimaryGun.ChildActor`（`BP_Weapon_*_C`，网格 `Weapon_Mesh`），手会自动换成握枪姿势。
  - 武器数据路径从 `CurrentlyEquipedWeapon.WeaponData` 读，例如 `/Game/ProjectLima/Blueprints/Data/DataAssets/Weapons/DA_Weapon_SMG.DA_Weapon_SMG`。
  - 变化时发 `PLAYER_GEAR`，另外每 10 秒重发一次。
- **开火**：hook `BP_Weapon_Base_C:FireProjectile`（每颗子弹一次），只认"本地玩家正拿着的那把枪"，发出镜头位置和朝向。
- **子弹**：另一边生成装饰子弹。
  - 结构：`StaticMeshActor`（可移动、无碰撞）+ `NiagaraComponent`（`NS_PRJ_StandardShot_v2`，游戏玩家子弹的拖尾）+ `ProjectileMovementComponent`（重力 0）+ `SetLifeSpan`。
  - 从化身枪口位置沿瞄准方向飞，速度 25000，最远 20000。
  - 不造成伤害：伤害仍由原来的 `damagesync` / `enemies` 转发。

## 实测发现（都是踩过的坑）

- **`IA_Fire` 注入不开枪，`IA_Shoot` 才开枪。**
  - 注入方式：`EnhancedInputLocalPlayerSubsystem:InjectInputVectorForAction(IA_Shoot, {X=1}, {}, {})`。
  - 路径：`/Game/FirstPerson/Input/Actions/IA_Shoot.IA_Shoot`。
  - 注入 60 帧时，`FireProjectile` 和 `ProjectileFireAudio` 各 47 次，弹匣 34 → 9。
- **`BP_Weapon_Base_C` 上的 hook**：
  - `FireProjectile`、`FireServerProjectile`、`ProjectileFireAudio`、`CustomFire_Gauss`、`FireRicochetProjectile` 都能注册。
  - `ShotFired`、`FireWeapon` 是委托，不是函数，注册失败。
- **武器子 Actor 的 `GetOwner()` 是空的**，不能用 Owner 判断是谁的枪；要和 `player.CurrentlyEquipedWeapon` 比地址。
- **化身会建自己的 HUD**：每个 `CH_LimaCharacter_C` 都有自己的 `PlayerIcons`（`WBP_PlayerIcons_C`）和 `MissionHUD`，而且是可见的，盖在我们的 HUD 上。
  - 现象：给化身 `GiveWeapons(霰弹枪)` 后，本地 HUD 变成霰弹枪图标，"6" 叠在 "45" 上。
  - 处理：avatars 把化身的这两个控件折叠（`SetVisibility(1)`）。
  - 房主的仇恨替身从 3.4b 起就有这个问题，以前两边都拿同一把枪，所以没看出来。
- **站在一起时队友的枪会盖住自己的枪**。两人读同一个存档，所以出生在同一点。化身离本地玩家不到 120 时，隐藏手、手套、枪。
  - 检查的是真实可见状态，不靠缓存：`GiveWeapons` 会换一把新的、可见的枪。
- **傀儡在关卡重载后重建**（客户端读进房主世界时），旧的"网格已隐藏"缓存会让新人偶一直显示，人偶从里面看是头顶上的黑色 V 形。`puppets.lua` 也改成按真实状态检查。
- **测试脚本的坑**：
  - `LoopInGameThreadWithDelay` 回调返回 true 并不会停止，要 `CancelDelayedAction(自己的句柄)`。
  - 句柄编号是一个 Lua 状态里共用的小整数，按范围取消会把 VBDev 自己的服务循环也取消掉。
  - 后台窗口帧率低，"400 次"要跑好几分钟。

## 自测结果

- A 看 B：手（袖子 + 手套）握着 SMG，侧面能看清，枪口方向和 B 的朝向一致；B 开火时从枪口飞出白色子弹拖尾（截图）。
- 计数：
  - B 开火 66 次 → A 显示 69（含之前排队的）。
  - A 开火 135 次 → B 显示 135。
  - 最后一轮 B 64 → A 64。
- 给化身换霰弹枪：化身手里变成霰弹枪；本地 HUD 不再被改。
- 两人同一位置：本地视角干净，没有队友的枪、没有人偶。
- 编解码自检 31/31。

## 没做 / 已知限制

- 化身只有手和枪，看不到身体（`CharacterMesh0` 从外面什么都不显示），看起来是"漂浮的手和枪"，上面有名字牌。
- 枪口火光、开枪音效、换弹动画都没有同步，只有子弹拖尾。
- 第二把武器（`GiveWeapons` 的第二个参数）不同步，化身只拿当前那把。
