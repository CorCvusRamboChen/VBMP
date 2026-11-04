# 联机 UI 设计（v1 草案）

- 日期：2026-11-04，build `23764881`
- 代码：`src/lua/VBMP/Scripts/hud.lua`（纯展示 + 本地采样，不收发网络包）
- 出处约定：**CXX** = `research/_local/dumps/23764881-20261104-024205/CXXHeaderDump/<文件>`，**UHT** = 同目录 `UHTHeaderDump/<模块>/Public/<文件>`，**OBJ** = 同目录 `UE4SS_ObjectDump.txt`，**清单** = `research/_local/filelist-23764881.tsv`
- 标 ❓ 的是转储里查到了接口，但行为还没在游戏里验证；标 🔍 的是转储里找不到、要先探针/转储再写

## 0. 总体做法

和 VBTools 的背包面板（`src/lua/VBTools/Scripts/ui.lua`，已验证）一样：**运行时用 `StaticConstructObject` 在游戏自己的 UserWidget 的 `WidgetTree` 里造 UMG 控件，挂到它的根 CanvasPanel 上**。不新建 UserWidget 类，不需要编辑器。

| 宿主 | 类 / 字段 | 出处 | 放什么 |
|---|---|---|---|
| 常驻 HUD | `UWBP_PlayerIcons_C`；通过 `ACH_LimaCharacter_C.PlayerIcons` 找到（也可以 `FindAllOf`）；根面板 `WidgetTree.RootWidget`，退路 `MainCanvas : UCanvasPanel` | CXX `WBP_PlayerIcons.hpp`、`CH_LimaCharacter.hpp:247`；资源 `/Game/ProjectLima/UI/Widgets/PlayerPrompts/WBP_PlayerIcons`（清单）；OBJ 第 272131 行：实例的 Outer 是 `GI_LimaGameInstance_C`，所以**跨关卡常驻**，`MainCanvas` 是它 WidgetTree 里的 CanvasPanel | 队友血条、倒地/复活提示、通知、队友名字牌 |
| 背包 | `UWBP_PlayerInventoryMain_C`（`IsActivated()` 判断打开），根面板同上 | CXX `WBP_PlayerInventoryMain.hpp`；ui.lua 已验证 | 队友鼠标、队友拖拽高亮 |

- 所有我们造的控件都设成 `HitTestInvisible`（`ESlateVisibility` = 3，CXX `UMG_enums.hpp:48`），**不会挡住游戏背包的点击和拖放**。
- 字体：借 `PlayerIcons.VoidCoins.Font`（`UTextBlock`），背包里借 `InventoryWidget.VoidiumText.Font`。游戏带 zh-Hans-CN，字体能显示中文（ui.lua 已验证）。这也顺带解决了 `docs/networking.md` 里"傀儡名字牌 TextRender 显示中文可能是方块"的问题：名字牌改成屏幕空间的 UMG 文字。
- 用到的 UMG 函数（全部在 CXX `UMG.hpp`，参数个数已核对）：`UCanvasPanel.AddChildToCanvas(Content)`、`UCanvasPanelSlot.SetAnchors/SetAlignment/SetPosition/SetSize/SetAutoSize/SetZOrder`、`UVerticalBox.AddChildToVerticalBox`、`UHorizontalBox.AddChildToHorizontalBox`、`UContentWidget.SetContent`、`UPanelWidget.ClearChildren`、`UBorder.SetBrushColor/SetPadding`、`USizeBox.SetWidthOverride/SetHeightOverride`、`UProgressBar.SetPercent(float)/SetFillColorAndOpacity(FLinearColor)`、`UTextBlock.SetText(FText)/SetFont/SetColorAndOpacity(FSlateColor)`、`UWidget.SetVisibility/SetRenderOpacity/RemoveFromParent/GetCachedGeometry`
- 刷新：`hud.lua` 自己开一个 50 ms 的 `LoopAsync` + `ExecuteInGameThread`（和 ui.lua 一样）。控件只在"队友名单变了"时重建，其余每次只改文字/百分比/颜色（文字有缓存，没变就不调 `SetText`）。名字牌需要逐帧更新，由 `main.lua` 在 `ReceiveTick` 钩子里调 `hud.frame()`。
- 出错保护：tick 出错就关掉 HUD 并记日志（和 ui.lua 一样），不影响游戏。

## 1. 队友 HUD（常驻）

### 1.1 外观

屏幕左侧（锚点 `(0, 0.36)`），每个队友一行：

```
┌────────────────────────────┐
│ 名字               48 ms   │   ← 名字（队友色），延迟（>150 ms 变黄，>300 ms 变红）
│ ███████████░░░░░  72/100   │   ← 血条（倒地变红，掉线变灰）
│ 倒地 · 张三 正在复活 63%    │   ← 状态行（只在有状态时显示）
│ ████████░░░░░░░░           │   ← 复活进度条（只在复活中显示）
└────────────────────────────┘
```

状态行内容（优先级从高到低）：掉线 / 重连中、倒地（复活中 x% / 等待复活）、在其他区域（关卡名不同）、背包中（对方背包打开，来自 CURSOR 消息的 open 位）。

### 1.2 本地玩家倒地 / 复活提示（屏幕中下）

- 自己倒地：大字"你倒地了"，下面"等待队友复活"或"张三 正在复活你"+ 进度条。
- 自己在复活别人：只显示"正在复活 李四"+ 进度条。
- 靠近倒地的队友（还没按键）：显示"按住 [交互] 复活 李四"。按键名先写死"交互"，🔍 以后从输入映射 `IA_Interact` 取真实按键。
- 游戏自带的交互长按条在 `WBP_PlayerIcons_C.InteractProgress / StartLongInteract()`（CXX），但它绑着游戏自己的交互逻辑，**不复用**，用我们自己的进度条，避免互相干扰。

### 1.3 队友名字牌（屏幕空间）

- `UWidgetLayoutLibrary.ProjectWorldLocationToWidgetPosition(PlayerController, WorldLocation, ScreenPosition&, bPlayerViewportRelative) -> bool`（UHT `UMG/Public/WidgetLayoutLibrary.h:79`，4 个参数，`ScreenPosition` 是输出结构体 → 传表）
- 名字牌放在傀儡头顶（世界坐标 +Z），队友倒地时变成红色"⚠ 名字 倒地 23m"，跑出屏幕时贴在屏幕边缘，方便找人复活。
- 坐标由 `main.lua` 每帧推给 `hud.setTeammateWorldPos(id, x, y, z)`（傀儡插值后的位置）。
- puppets.lua 里的 TextRender 名字牌可以在这个验证通过后关掉。

### 1.4 网络消息（主会话接入 `codec.lua` / `session.lua`）

权威：**每个玩家的血量由他自己的客户端上报**（客户端执行房主发来的伤害事件后，自己角色上的 `Health` 就是真值）；**倒地 / 复活状态由房主决定并广播**（"全员倒地才失败"要由一个人判定）。

| 消息 | 方向 | 格式（`string.pack`） | 字段 | 频率 / 通道 |
|---|---|---|---|---|
| `PLAYER_HP` | 任意 → 房主 → 转发 | `"<ffB"` | hp、maxHp、flags（bit0 倒地中，bit1 已死亡 / 出局） | 变化超过 1 点或 flags 变化时发，最多 10 Hz；另外每 2 秒重发一次。不可靠 |
| `DOWNED` | 房主 → 全体 | `"<i8B"` | 目标 SteamID64、状态（0 正常 / 1 倒地 / 2 出局） | 状态变化时，可靠 |
| `REVIVE_REQ` | 客户端 → 房主 | `"<i8B"` | 目标 SteamID64、动作（1 开始长按 / 0 松开） | 按下和松开时各一次，可靠 |
| `REVIVE` | 房主 → 全体 | `"<i8i8f"` | 目标、救援者（0 = 没人在救）、进度 0–1 | 有人在救时 10 Hz（不可靠）；开始、取消、完成时各发一次可靠的 |

- 血量来源（CXX `CH_LimaCharacter.hpp:267-268`）：`ACH_LimaCharacter_C.Health / MaxHealth : double`。
- 延迟不需要新消息：`session.lua` 已经有 PING/PONG（`p.rtt`）。注意客户端只和房主通信，所以**客户端看到的其他客户端延迟 = 未知**；v1 只显示"我到这个人的 RTT"（房主看到每个人的，客户端只看到房主的），其他人显示"-"。要显示全队延迟，房主可以把 `p.rtt` 塞进转发的 PLAYER_HP 里（再加一个 `H` 字段），v2 再说。
- 倒地的实现（拦截死亡、`ReviveFromEntropy()`、`CinematicLock`）在 `docs/coop-rules.md`，不是 UI 的事；UI 只吃上面的状态。

## 2. 共享背包里的队友鼠标

### 2.1 采样（本机，`hud.getLocalCursor()`）

| 要什么 | 怎么取 | 出处 |
|---|---|---|
| 背包是否打开 | `WBP_PlayerInventoryMain_C:IsActivated()` | ui.lua 已验证 |
| 鼠标位置（Slate 单位，视口内） | `Default__WidgetLayoutLibrary:GetMousePositionOnViewport(WorldContext) -> FVector2D` | UHT `WidgetLayoutLibrary.h:97` |
| 视口像素大小、DPI 缩放 | `GetViewportSize(WorldContext) -> FVector2D`、`GetViewportScale(WorldContext) -> float` | UHT `WidgetLayoutLibrary.h:85/88` |
| 是否在拖东西 | `Default__WidgetBlueprintLibrary:IsDragDropping() -> bool`、`GetDragDroppingContent() -> UDragDropOperation*` | UHT `UMG/Public/WidgetBlueprintLibrary.h:115/142` |
| 拖的是哪一格 | `UDragDropOperation.Payload : UObject*` ❓（期望是 `UWBP_Button_InventorySlot_C`，即游戏 `OnDragDetected` 里把格子自己当 Payload；没验证）；格子在 `WBP_PlayerInventoryMain_C.WeaponSlotWidget : UWBP_WeaponSlot_C` 的 `InventorySlotArray`（背包）/ `Weapon01SlotArray` / `Weapon02SlotArray` 里的下标 | UHT `UMG/Public/DragDropOperation.h:20`；CXX `WBP_WeaponSlot.hpp:30-33`、`WBP_Button_InventorySlot.hpp` |
| 物品名字 | 格子 `SlotInformation : FSTR_StackInformation` 的 `MasterDetails_20_02C613244058148ADEB15795ACD96292 : UPDA_MasterDetails_C*` → `ModName : FText` | CXX `STR_StackInformation.hpp`、`PDA_MasterDetails.hpp:6` |

坐标换算：`nx = mouse.X * scale / viewport.X`，`ny` 同理，得到 0–1 的屏幕比例。

### 2.2 显示（`hud.setRemoteCursor(id, x, y, visible, drag)`）

- 每个队友一个小方块（队友色）+ 名字；拖东西时名字后面加"拖着：物品名"。
- 位置用**锚点**放：CanvasPanelSlot 的 `Anchors.Minimum = Maximum = (x, y)`、`Position = (0,0)`，所以接收方不用知道视口大小（前提：背包根 CanvasPanel 铺满屏幕，ui.lua 把面板锚到 `X = 1` 就贴着屏幕右边，说明是铺满的）。每 50 ms 向目标位置插值一半，看起来是连续移动。
- 拖的是**共享背包**的格子时，在接收方自己背包的同一格（同一下标）上盖一个半透明的队友色框：
  - 格子的屏幕矩形：`slot:GetCachedGeometry()`（UHT `UMG/Public/Widget.h:295`）→ `Default__SlateBlueprintLibrary:LocalToAbsolute(Geometry, {0,0})`、`GetAbsoluteSize(Geometry)` → 用根面板的 Geometry `AbsoluteToLocal(RootGeometry, abs)` 换成根面板坐标（UHT `UMG/Public/SlateBlueprintLibrary.h`，参数个数 2/1/2）
  - ❓ `FGeometry` 在反射里没有可见字段，UE4SS 把它作为返回值拿到、再当参数传回去能不能保持内容，**没验证**。失败时 `hud.lua` 只记一次日志并关掉高亮，名字后的"拖着：物品名"照常显示。
- 拖的是**武器**格子（个人的）时，不在别人的背包里高亮（别人看到的是自己的武器格），只显示"拖着：物品名"。
- 已知局限：两边屏幕宽高比不同时，背包布局的比例位置不一样，鼠标会"偏"。真要精确，可以改成"相对背包网格 `WeaponSlotWidget` 的坐标"（同样用上面的 Geometry 函数），等 v1 验证 Geometry 能用以后再做。

### 2.3 网络消息

| 消息 | 方向 | 格式 | 字段 | 频率 / 通道 |
|---|---|---|---|---|
| `CURSOR` | 任意 → 房主 → 转发 | `"<HHBBH"` | x、y（0–65535 表示 0–1）、flags（bit0 背包打开，bit1 正在拖）、拖的格子类型（0 背包 / 1 武器 1 / 2 武器 2）、格子下标（从 1 开始；0 = 无） | 背包打开时 15 Hz，位置或 flags 没变就不发；关背包时发一次 flags=0（可靠）。不可靠 |
| `DRAG_ITEM` | 任意 → 房主 → 转发 | `"<s1"` | 正在拖的物品名（空串 = 放下） | 开始拖 / 放下时各一次，可靠 |

- 物品名单独发，避免 15 Hz 的包里带字符串。
- 拖放本身（从共享背包拿走、放回）的**结果**由房主仲裁（`docs/coop-rules.md`：`AddToInventoryIndex` 那条），不在 UI 消息里。

## 3. 敌人血条（客户端显示房主的数值）

### 3.1 游戏的敌人血条是怎么工作的（转储能看到的部分）

- 每个敌人身上有 `HealthBar : UWidgetComponent`，缓存的控件 `As WBP Enemy Health Bar : UWBP_EnemyHealthBar_C`、`HealthUI : UUserWidget`（CXX `CH_AI_Base.hpp:9/23/48`）。
- 数值字段（全是 double）：`Health`、`MaxHealth`、`ShieldHealth`、`ShieldMaxHealth`、`ArmourHealth`、`ArmourMaxHealth`、`StaggerHealth`、`StaggerMaxHealth`；显示状态 `ShowingHealthBar? : bool`（CXX `CH_AI_Base.hpp:24-34/92/115`）。
- 刷新入口（都在 `ACH_AI_Base_C`，**无参数**）：`SetHealthBar()`、`SetShieldBar()`、`SetStaggerBar()`、`ShowHealthBar()`、`HideEnemyHealthBar()`、`SetHealthBarRank()`。另有 `SetMaxAndCurrentHealth(CurrentHealth, MaxHealth)`、`GetHealthBarInformation(...)`。
- 控件本身（`UWBP_EnemyHealthBar_C`）**没有 Tick**（转储里没有 `Tick` 函数），只有被推送的函数：`SetHealthBarWidget(NewHealth, TotalHealth, ReceivingDamage?, DamageReceived, ShieldType, CriticalElement?)`（6 参，来自 `BPI_HealthUI`）、`SetShieldBar(NewHealth, TotalHealth, ReceivingDamage?, DamageReceived)`（4 参）、`SetStaggerWidget(StaggerHealth, MaxStaggerHealth)`、`SetDamageNumber(DamageAmount, Critical?, Resistance)`、`InitiateHealthBar(...)`。
- 玩家 HUD 顶部还有一条"当前瞄准的敌人"血条：`WBP_PlayerIcons_C.WBP_EnemyHealthBar` + `ShowEnemyHealthBar(Health, TotalHealth, Name, ProtectionType, Rank, PawnRef, StaggerHealth, StaggerMaxHealth)`，入口是 `ACH_LimaCharacter_C.CLIENT_ShowEnemyHealthBar(UObject* Target)`（CXX `CH_LimaCharacter.hpp:1364`）。
- 显示模式设置：`GI_LimaGameInstance_C.HealthBarSetting : Enum_HealthBarMode`（两种）、`ShowEnemyHealthBars? : bool`。
- Boss：`ACH_AI_Boss_C.WBP Boss Health Bar : UWBP_BossHealthBar_C`，`SetHealthBar(NewHealth, TotalHealth, ReceivingDamage?, DamageReceived, ShieldType, CriticalElement?, StaggerHealth, StaggerMaxHealth)`（8 参）。

### 3.2 结论

**只写数值字段不够**：头顶血条是"推"出来的（控件没有 Tick），只改 `Health` 不会刷新显示。客户端在写完字段后要调用刷新入口：

1. 写 `Health / MaxHealth / ShieldHealth / ArmourHealth / StaggerHealth`
2. 如果 `ShowingHealthBar?` 为 false，调 `ShowHealthBar()`（客户端的敌人从没挨过本地伤害，游戏不会自己把血条显示出来）
3. 调 `SetHealthBar()`、`SetShieldBar()`、`SetStaggerBar()`
4. 掉血数字（可选）：`As WBP Enemy Health Bar:SetDamageNumber(伤害, 是否暴击, 抗性)`

`hud.applyEnemyHealth(enemy, t)` 实现了 1–3，每一步单独 pcall，失败只记一次日志。

❓ 需要探针确认（VBTrace 加钩子，单机打几只怪即可）：
- 正常受伤时的调用顺序是不是 `ApplyDamage → SetHealth → SetHealthBar/SetShieldBar`，`SetHealthBar()` 是不是只读字段刷新 UI（有没有顺带判死亡、播音效、加元素层数）
- 顶部瞄准血条 `CLIENT_ShowEnemyHealthBar` 是不是每次都从 `GetHealthBarInformation` 读字段（是的话写字段就够了）
- 客户端血量写到 0 会不会触发什么：**v1 先把客户端血量钳在 ≥ 0.001**，死亡走单独的"敌人死亡"消息（sync-design 第 4 节），不靠血条
- Boss 血条的刷新入口（`ACH_AI_Boss_C` 的哪个函数调 `WBP Boss Health Bar:SetHealthBar`）

### 3.3 补充方案（如果上面的刷新入口有副作用）

直接调控件：`enemy["As WBP Enemy Health Bar"]:SetHealthBarWidget(hp, maxHp, false, 0, 护盾类型, false)` + `SetShieldBar(...)` + `SetStaggerWidget(...)`，参数个数见 3.1。护盾类型 `Enum_ShieldType` 取值 🔍 待查。再不行就在 HUD 里自己画一条"瞄准目标血条"。

### 3.4 网络消息

| 消息 | 方向 | 格式 | 字段 | 频率 / 通道 |
|---|---|---|---|---|
| `ENEMY_HP` | 房主 → 全体 | `"<I4fffffB"` | NetID、hp、maxHp、shield、armour、stagger、flags（bit0 有伤害数字，bit1 暴击） | 某个敌人数值变化时，每个敌人最多 10 Hz，合并发送；不可靠，最后一次（死亡前）可靠 |
| `ENEMY_DMG`（可选） | 房主 → 全体 | `"<I4fBB"` | NetID、伤害、暴击、抗性 | 每次命中，不可靠；只用来出伤害数字 |

依赖：敌人 NetID 映射（`docs/sync-design.md` 第 2 节），还没有实现。在此之前，主会话可以先在**同一台机器**上验证：单机里挑一只敌人，调用 `hud.applyEnemyHealth(enemy, { hp = maxHp * 0.3 })`，看头顶血条是否变成 30%。

## 4. 通知（`hud.notify(text, color, seconds)`）

左上偏下的一列 toast，最多 5 条，默认 5 秒淡出。也可以改用游戏自己的通知队列：`WBP_PlayerIcons_C.CreateNotification(UUserWidget*, float DelayBeforeFading)` + `WBP_Notification_GenericText_C.SetText(FText)`（CXX；资源 `/Game/ProjectLima/UI/Widgets/Notifications/NotificationPlayer/WBP_Notification_GenericText`），需要先 `WidgetBlueprintLibrary.Create` 出控件，🔍 v1 不做。

| 事件 | 来源 | 需要新消息吗 |
|---|---|---|
| 队友加入 / 离开 / 掉线（超时） | `session.lua` 的 `addPeer` / `dropPeer` | 不需要 |
| 自己与房主断开、连接超时、被拒绝 | `session.lua` 的 `S.state` / `S.error` | 不需要 |
| 队友倒地 / 被复活 / 出局 | `DOWNED`、`REVIVE` | 见 1.4 |
| 谁拾取了什么（模组、遗物、货币） | 房主仲裁拾取后广播 | **`EVENT`**（见下） |
| 共享背包：谁从背包拿走了什么、拿失败（被别人先拿了） | 房主仲裁 `AddToInventoryIndex` 后 | `EVENT` |
| 谁用了全队生效的能力（时停等） | 房主执行后 | `EVENT` |

`EVENT`：房主 → 全体，`"<Bi8s1i4"`：类型、主角 SteamID64、文字参数（物品名等）、数量。可靠。文字在接收端本地拼（"张三 拾取了 冰冻弹 ×2"），以后好做本地化。类型表：1 拾取物品、2 拾取货币、3 从背包拿走、4 放回背包、5 拿取失败、6 使用全局能力、7 房主广播文本。

## 5. 联机还需要的 UI（盘点）

| # | UI | 优先级 | 说明 |
|---|---|---|---|
| 1 | 队友血条 + 延迟 | P0 | 本文第 1 节，v1 已实现 |
| 2 | 倒地提示 / 复活进度 / "按住复活" | P0 | 第 1.2 节，v1 已实现；规则里**没有定流血倒计时**（倒地多久没人救就出局），要和用户确认 |
| 3 | 队友名字牌 + 倒地方位（贴屏幕边） | P0 | 第 1.3 节，v1 已实现；替代 TextRender 名字牌（中文方块问题） |
| 4 | 掉线 / 重连 / 加入 / 离开 toast | P0 | 第 4 节，接 session 事件即可 |
| 5 | 背包里的队友鼠标、拖拽高亮 | P1 | 第 2 节，v1 已实现（高亮 ❓） |
| 6 | 拾取 / 背包变化通知 | P1 | 第 4 节 `EVENT` |
| 7 | 敌人血条显示房主数值 | P1 | 第 3 节，等 NetID |
| 8 | 联机状态角标（房主/客户端、人数、自己的延迟） | P1 | 现在在 VBTools 背包面板里；可以在 HUD 角上常驻一行小字，`hud.setStatus(text)` 已提供 |
| 9 | 全员倒地 → 失败结算 | P1 | 走游戏原来的 `WBP_DeathScreen`（`HandleDeathUI`），只要房主在全员倒地时才放行死亡流程 |
| 10 | 打开菜单 / 背包时不暂停的提示 | P2 | 单机打开菜单会暂停世界吗 🔍 要测；联机下不能暂停，可以在队友行显示"背包中/菜单中" |
| 11 | 关卡切换等待（"等待房主加载" / "等待 XX 进入下一关"） | P2 | 进传送门时房主等全员；需要新消息 `READY`（客户端 → 房主，关卡名） |
| 12 | 标记 / Ping（"这里有东西"） | P2 | 中键标记，世界坐标 + 名字牌同样的投影方式 |
| 13 | 商店 / 宝箱"谁在用"占用提示 | P2 | 多人同时开同一个终端时，房主拒绝后显示"XX 正在使用" |
| 14 | 结算页：每人击杀、伤害、拾取 | P3 | 玩法确定后再说 |

## 6. 待转储 / 待探针确认

1. 🔍 `UDragDropOperation.Payload` 在游戏拖格子时实际是什么对象（期望 `WBP_Button_InventorySlot_C`）
2. ❓ `FGeometry` 作为返回值再传回 `USlateBlueprintLibrary` 函数能否保持内容（决定拖拽高亮能不能用）
3. ❓ `WBP_PlayerIcons_C` 的 `WidgetTree.RootWidget` 是不是 `MainCanvas`、是否铺满屏幕；HUD 被游戏隐藏（`SetHUDCinematicMode`、菜单）时我们的控件跟着隐藏是期望行为
4. ❓ `ACH_AI_Base_C.SetHealthBar()/SetShieldBar()/SetStaggerBar()/ShowHealthBar()` 的副作用（第 3.2 节）
5. 🔍 `Enum_ShieldType`（4 个值）、`Enum_ResistanceType` 在转储里只有 `NewEnumerator0…` 这样的名字（CXX `Enum_ShieldType_enums.hpp`），含义要靠探针记录正常受伤时传的值来对应（补充方案和伤害数字要用）
6. 🔍 交互键的显示名（"按住 [E] 复活"）：从 Enhanced Input 的 `IA_Interact` 映射取
7. ❓ `GetMousePositionOnViewport` 在 CommonUI 背包里（鼠标模式）返回值正常；手柄模式下没有鼠标，v1 直接不发 CURSOR
8. ❓ 两台机器的 `InventorySlotArray` 下标一一对应（共享背包大小一样、顺序一样）。高亮用的是"同一下标"

## 7. 接入步骤（给 main.lua / session.lua）

1. `main.lua`：`local hud = require("hud")`，加载时 `hud.start({ log = log })`；在 `renderStep()` 末尾调 `hud.frame()`（名字牌逐帧跟随）；找个空热键调 `hud.toggle()`
2. 傀儡位置：`renderStep` 里对每个傀儡 `hud.setTeammateWorldPos(id, loc.X, loc.Y, loc.Z)`（puppets 需要暴露每个 id 的当前位置；没有就传 nil）
3. `session.lua`：
   - `addPeer` → `hud.setTeammate(id, { name = name, connected = true })` + `hud.notify(name .. " 加入了", hud.COLOR.green)`
   - `dropPeer` → `hud.notify(name .. " 离开了（" .. why .. "）", hud.COLOR.yellow)` + `hud.removeTeammate(id)`；超时可以先 `setTeammate(id, { connected = false })` 留几秒再删
   - PONG 算出 `p.rtt` 后 → `hud.setTeammate(id, { ping = p.rtt })`
   - LEVEL 收到后 → `hud.setTeammate(id, { otherLevel = (p.level ~= 自己的关卡) })`
   - `S.state` 变成 failed 时 → `hud.notify(S.error, hud.COLOR.red, 8)`；`hud.setStatus(模式 .. " · " .. 人数 .. " 人")`；`stop()` 时 `hud.clear()`
4. 新消息（第 1.4 / 2.3 / 3.4 / 4 节的表）加进 `codec.lua` 的 `T` 和 `BODY`，并加进 main.lua 的 selfTest。房主对 `PLAYER_HP`、`CURSOR`、`DRAG_ITEM` 像 STATE 一样原样转发
5. 发送端：
   - 每 ~66 ms：`local c = hud.getLocalCursor()`；`c.open` 时把 `c.x/c.y` 乘 65535 取整发 `CURSOR`（变了才发），`c.drag` 变了发 `DRAG_ITEM`；从 open 变成关时发一次 flags=0
   - 自己的血量：读本地 `CH_LimaCharacter_C.Health/MaxHealth`，按 1.4 的频率发 `PLAYER_HP`
6. 接收端：`PLAYER_HP` → `hud.setTeammate(id, { hp, maxHp, downed })`；`CURSOR`+`DRAG_ITEM` → `hud.setRemoteCursor(id, x/65535, y/65535, open, { kind, index, item })`；`DOWNED`/`REVIVE` → 目标是自己时 `hud.setLocalDown(...)`，是别人时 `setTeammate(id, { downed, reviveProgress, reviver })`，自己是救援者时 `hud.setReviveAction(name, p)`；`ENEMY_HP` → 按 NetID 找到本地敌人后 `hud.applyEnemyHealth(enemy, t)`；`EVENT` → 拼文字后 `hud.notify`
7. 先单机验收（不需要第二台电脑）：本机回环模式里，回环的假队友会走同样的 addPeer/PONG/STATE 路径，能看到队友行和名字牌；用控制台或临时热键调 `hud.setTeammate(1, "测试", 30, 100, true, 0.4)`、`hud.setLocalDown({ reviver = "测试", progress = 0.5 })`、`hud.notify("测试通知")`、`hud.setRemoteCursor(1, 0.5, 0.5, true, { kind = 0, index = 1, item = "测试" })`（打开背包看），以及对 `FindFirstOf("CH_AI_Base_C")` 调 `hud.applyEnemyHealth(e, { hp = e.MaxHealth * 0.3 })` 看头顶血条

### 验收标准

| 项 | 画面 | 日志 |
|---|---|---|
| HUD 挂载 | 屏幕左侧出现队友行 | `[VBMP] hud: layer attached to WBP_PlayerIcons_C.RootWidget`（或 `.MainCanvas`） |
| 倒地提示 | 屏幕中下"你倒地了 / 测试 正在复活你"+ 进度条 | 无 `hud: error` |
| 名字牌 | 回环傀儡头顶有名字；`downed = true` 时红字 + 距离，转身后贴在屏幕边 | 无 `ProjectWorldLocationToWidgetPosition failed` |
| 背包鼠标 | 打开背包，(0.5, 0.5) 处有队友色小方块 + "测试 拖着：测试"，第 1 格有半透明框；**背包里的拖放照常能用** | `layer attached to WBP_PlayerInventoryMain_C…`；没有 `drag highlight disabled`（有的话说明 FGeometry 往返不行） |
| 本地鼠标采样 | 打开背包拖一个模组时，`hud.getLocalCursor()` 返回 `drag.kind = 0`、正确的下标和名字 | 没有 `drag payload is …, expected WBP_Button_InventorySlot_C` |
| 敌人血条 | 敌人头顶血条变成 30% | 没有 `applyEnemyHealth … failed` |
