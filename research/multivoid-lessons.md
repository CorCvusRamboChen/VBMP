# Multivoid 联机 mod 调研：对 VOID/BREAKER 有用的设计经验

- 日期：2026-11-04
- 对象：`VOTV-MP/Multivoid`（MIT），Voices of the Void（UE 4.27，大部分逻辑是蓝图）的 1 房主 + 最多 3 客户端随时加入合作 mod。C++ DLL 由 UE4SS 加载，但不导入 UE4SS 的任何符号
- 读过的材料：`README.md`、`CONTRIBUTING.md`，`docs/` 下的 architecture、coop-sync-doctrine、coop-dispatch-visibility（第 1–100 行和第 258 行到结尾）、coop-entity-expression-map（身份区间、角色、爆炸、去重矩阵几节）、status、scope、props、npcs-and-kerfur、players、join、send-path、versioning、testing、re-workflow、voice-and-chat、events-and-weather（Who rolls 到 Known limits）、code-map、bytecode-fingerprint（前半）、feasibility、devs-gauntlet、README（标签说明）；源码读了 `include/coop/net/protocol.h`（头部、MsgType、ReliableKind 枚举、PacketHeader、PoseSnapshot、EntityPose 结构）、`include/coop/element/lerp_window.h`、`src/coop/creatures/npc_pose_host.cpp` / `npc_pose_drive.cpp`、`src/coop/net/session_lanes.h`（前半）、`src/coop/net/session_streams.cpp`（发送节拍那段），另外 grep 过 `session.cpp`
- 没读的：piles、signals、devices、vehicles、deployables、ui、credits、master-server、release 这几页，以及 coop-dispatch-visibility 中间那张大函数表的大部分
- 约定：文中路径都相对于 Multivoid 仓库根目录；`coop/...`、`ue_wrap/...` 是 `src/votv-coop/src/` 下的路径。**标「推断」的是我根据读到的内容推出来的，对方文档里没有原话**

先说最关键的一点：Multivoid 的很多关键能力来自 C++，即 `ProcessEvent` detour、**蓝图 VM 脚本循环 detour（script gate，可以按调用取消蓝图函数体）**和原生函数 hook。我们只用 Lua，**不能照搬"在 hook 里取消"这种做法**，要换成别的"停住客户端自己的模拟"（park the brain）的方式。下文每节都标出了这点。

---

## 1. 让客户端的世界听房主的：关掉 AI、随机、事件和本地交互

### 他们怎么做

- **所有权表**（`docs/architecture.md`「Who owns what」、`docs/coop-sync-doctrine.md` Step 2）。每类状态按表里第一条匹配的规则定归属：
  - 共享世界的推进（天气、电力、事件、会自己变化的物体、NPC 大脑、**随机数**）→ 房主模拟或掷骰，客户端只镜像。"A client never rolls a shared outcome"（客户端从不掷共享结果）
  - 客户端发起的、离散的、会持久化的共享世界改变（买、卖、摧毁、放置、从容器里拿）→ **意图（intent）**。客户端**压掉自己这边的产生者**，只发"做什么"；房主校验、执行，按自己的表定价，结果作为普通状态下发。参考实现是 `coop/items/order_sync`
  - 某个玩家正在互动的连续模拟物体（手里拿着的道具、在开的车）→ 交给互动者（**由房主分配，不能自己声明**），房主校验，可以收回
  - 自己的身体、姿态、镜头、语音 → 归本人，接收方从不拦截
  - 表现层（UI、声音、粒子）→ 不归任何人，收到就镜像，从不回传
- **四条附加规则**（同上）：
  1. **被压制的永远是客户端那边的产生者，而不是接收端**。原文的意思是：在接收端拦截，会把"防作弊"变成"丢数据"，因为客户端合法的操作产生了仲裁者永远不知道的状态
  2. 意图只说"做什么"，不说"花多少"
  3. 仲裁者 hook 不到触发点时，让意图指向一个仲裁者能解析的东西（例如商店购买会留下一条订单记录，房主按记录定价）
  4. 房主可以作弊。所有边界和合理性检查只针对客户端，对房主做检查算 bug
- **"停住大脑"（Park the brain）**（`docs/architecture.md`、`docs/coop-sync-doctrine.md` Step 4）。如果镜像物体自己的蓝图还在跑，写进去的值会漂移或被它改回去。所以每个镜像都要**可恢复地**停住会覆盖它的东西，有三种方式：
  - **字段锁存**：写入停住时的值，游戏改回去就再写一次，权威回来时恢复原值
  - **停调度**：清掉或拦住驱动自模拟的 timer 或 tick，用慢速巡检确认它还是停的，所有权回来时恢复
  - **物理接收端**：远端拥有期间设成 kinematic，游戏重新打开模拟就再锁一次，释放时把速度还回去。**不要往静止的刚体里写线速度，写了它就会醒**
  - 禁止的做法：删 constraint、把实体"切掉大脑"、换成假的 Actor 类
  - 怎么判断一个"停住"是不是根因修复：停住前后各有几个"作者"。停住后只剩一个作者，就是根因修复（第二个作者被移除了）；如果被停住的一方只是因为"看不见"才安静（状态根本没同步过），那就是拐杖。**必须先把状态同步过去，再去停住**
  - 如果被停住的函数体里有接收方还需要的副作用，就**只压掉它产生的那一个输出**。例子：ATV 的碰撞委托照常整段执行，只是把冲量清零，否则车会陷进地里 25–40 cm
- **四种 hook 入口**（`docs/architecture.md`「Hooks and seams」，`docs/coop-dispatch-visibility.md`）：
  1. `ProcessEvent` 拦截器：能看到引擎发起的调用（tick、BeginPlay、输入、委托、timer、接口事件），**可以取消**
  2. **script gate**（对 VM 脚本循环的 detour）：能看到每一个蓝图函数体，包括蓝图内部的本地调用、Context 调用和 ubergraph 入口，**可以按单次调用取消**
  3. 原生函数 hook：能看到所有路径进入原生函数的调用；对没有返回值和输出参数的原生函数，可以在调用前拒绝
  4. **事后对账**（per-site reconcile）：让动作照常执行，比较可观察的状态，收敛到权威的答案
  - 核心规则："Visibility is a property of the dispatch path, not of the function"，能不能看到一个调用取决于它走哪条调用路径，而不是取决于函数本身。同一个 `K2_DestroyActor`，由引擎调用时可见，蓝图对自己调用时不可见。蓝图到蓝图的调用（`EX_LocalVirtualFunction`、`EX_FinalFunction`、`EX_CallMath` 等）**不经过 ProcessEvent**
  - 同一个 `BeginDeferredActorSpawnFromClass`，从刷怪器的原生调用方进来时可见，从蓝图图表里调用（`EX_CallMath`）时不可见（`coop-dispatch-visibility.md`「Visible and invisible」）
- **刷怪器 / 随机源的集中禁用表**（`docs/npcs-and-kerfur.md`「Which spawners a client refuses」，`docs/events-and-weather.md`「Who rolls」）。`coop/world/spawn_authority` 是唯一负责这件事的模块：每行是"客户端不能执行的函数体"（某个刷怪器的 tick 或入口函数），按类名和函数名在 script gate 上拒绝，只在客户端会话运行时生效，离开会话后不需要恢复任何东西。表里还写明了哪些**故意不禁**：
  - 跟着本地相机生成的萤火虫、松果：每个人掷自己的
  - 追踪本地玩家的 eyer：各自拥有，其他人看镜像
  - 不禁就会让客户端丢战利品、又没有房主替代的东西
- **事件调度器**（`docs/events-and-weather.md`「Story and scheduled events」）。客户端在每次时钟周期之前把自己的"可执行事件列表"清空（一次写一个整数），这样它的调度器什么也不会触发。房主在 `runEvent` / `runSpecialEvent` 函数体结束后广播。客户端收到后按**每个事件行各自的策略**处理：结果已经有专门通道同步的（物体、生物、车……）**不重放**，否则效果会出现两次；没有通道承载的（关卡切换、剧情 flag、装饰性声音）就用同一个原生函数重放
- **客户端的交互 → 意图**。例子：
  - 门、键盘、咖啡机、睡袋：客户端在 gate 上取消本地蓝图函数，发"元素 ID + 动作字节"；房主检查距离、占用、形态，然后**用该客户端的傀儡作为玩家参数调用同一个蓝图函数**（`docs/props.md`「Sleeping bags」，`coop-entity-expression-map.md` 去重矩阵里的咖啡机一行）
  - 意图发不出去时（物体还没有房主 ID），就退回到本地执行，不会吞掉玩家的操作（`props.md`）
- **"玩家服务对象"替身**（`docs/npcs-and-kerfur.md`）。游戏里有些逻辑读的是"玩家 0"（本地玩家），例如 kerfur 的"跟随"。房主执行客户端的命令时，把这些读取的结果换成发命令那个客户端的傀儡（`coop/creatures/served_player`），于是"跟随"会跟随那个客户端
- **其他全局压制**（`docs/status.md`「Enforced without a packet」）：
  - 客户端从不写存档
  - 客户端的共享刷怪器在 script gate 上被拒绝
  - 联机时不允许暂停，每个 tick 都把暂停解除

### 对 VOID/BREAKER 的借鉴

- **直接采用**："共享结果只有房主掷骰"、"压产生者，不在接收端拦"、"意图只说做什么"、"房主可以作弊，检查只对客户端"。这正好补上 `sync-design.md` §1 里"凡是会产生结果的逻辑都要关掉或接管"缺的那条操作原则：**关的是客户端的"产生者"，不是客户端收到房主消息后的应用**
- **Lua 的缺口**：我们没有 script gate（`phase2-04-interactions.md` §3B 已经注意到"UE4SS 的 hook 不能阻止蓝图函数执行"）。Multivoid 自己的四个入口里，**第 4 种"事后对账"和"停住大脑"的三种方式都不依赖"取消"**，可以按下面的顺序在 Lua 里替代（推断，每条都要用 VBTrace 探针验证）：
  1. **停调度**：对客户端的敌人、AI 控制器、刷怪器，调用 `SetActorTickEnabled(false)`、关掉组件 tick、`K2_ClearTimer`（按函数名）、`StopLogic` / `UnPossess` AI 控制器。这是 Multivoid 用来停 NPC 大脑的方式（`npcs-and-kerfur.md`：「AI timers neutralised and the movement tick off」）
  2. **字段锁存**：游戏的 `InteractEnabled?`、`CinematicLock` 这类布尔开关，就是我们在 Lua 里能用的"取消"（`phase2-04` §3B 已经想到）
  3. **出生即销毁**：Multivoid 处理客户端的爆炸，是在 deferred-spawn 之后把结果置空，再用投递任务销毁 Actor（`coop-entity-expression-map.md`「Explosions」）。我们可以用 `NotifyOnNewObject` 在客户端捕获"不该由客户端生成"的敌人、掉落、刷怪，然后 `K2_DestroyActor`（推断；要注意 BeginPlay 里已经产生的副作用）
  4. **事后对账**：做不到前三种时，让客户端的函数执行完，再按房主的状态强制改回来，例如 `ForceObjectState`（`sync-design.md` §3 L2 已经是这种形状）
- **刷怪器禁用表**：照着做一张 `spawn_authority` 式的**单一表**，"类名 + 要停掉的函数或 tick + 原因 + 是否故意保留"，放在一个 Lua 模块里管理，不要散落在各个通道里。我们的候选：`GM.SpawnEnemyImmediate`、`AddEnemyPool`、各刷怪点、宝箱掉落的随机……
- **事件按行定策略**：VOID/BREAKER 的 Scenario、Data Layer、biome 切换，就相当于他们的"事件"。房主广播"选了哪个 Scenario"之后，客户端要逐项决定"重放这个调用"还是"不重放，靠状态通道"，否则同一个结果会出现两次
- **"服务对象"替身很关键**：我们的 `DealDamageToPlayer`、`TraceForEnemyToThrowAt`、敌人选目标，很可能读的是 `GetPlayerCharacter(0)`。房主替客户端执行意图（开箱、交互、投掷）时，蓝图里的"玩家"会是房主自己（推断，要逐个查函数体）。参考 `served_player`：在房主执行期间把"玩家"换成那个客户端的傀儡；做不到就只能由房主重算结果

---

## 2. NPC / 生物同步

### 他们怎么做

- **生成和身份**（`docs/npcs-and-kerfur.md`「Host-owned characters」，`coop-entity-expression-map.md`「Characters」）：
  - 房主在 deferred-spawn 调用上挂拦截器，对白名单里的角色类分配元素 ID，生成完成后绑定，再广播 `EntitySpawn`（类、ID、Transform、缩放、是否随存档持久化）
  - **客户端自己生成同类角色时，在同一个调用上直接取消**
  - 拦截器看不到的出生方式另外登记：随关卡加载的角色在世界开始时扫描一遍；蓝图图表里生成的（`EX_CallMath`）在原生函数 hook 上按"是哪个类在生成"过滤
  - 随存档持久化的角色，客户端在加载后按类型认领本地那份（`npc_adoption`），不再生成第二份
- **停住镜像的大脑**：中和 AI timer、关掉移动组件 tick；只有 tick 纯属本地表现的类（wisp 的淡入淡出和浮动）保留 Actor tick。僵尸和 fossilhound 走得更远：镜像上的事件图表**逐个入口拒绝**，只留脚步声这类（`npc_mirror_brain`）。Geom Octa 反过来：保留它的 BeginPlay、tick、动画时间线和声音，**只拒绝 12 个"做决定"的入口**（游荡、选目标、离开、开火判定），房主的决定作为 `GeomOctaEvent` 发下来，在镜像自己的蓝图里重放（`npcs-and-kerfur.md`）
- **姿态流**（`protocol.h` 的 `EntityPose` / `EntityPoseSnapshot`，`coop/creatures/npc_pose_host.cpp`）：
  - 每个 tick 一批，不可靠、新的覆盖旧的
  - 每条 44 字节：元素 ID、xyz、yaw、水平速度（驱动走跑混合）、可选的注视点 lookAt、可选的身体 yaw、状态位（在空中 / 有 lookAt / 有 bodyYaw / kerfur 状态）、kerfur 命令状态、表情编号
  - 一个数据报最多 31 条（按 1400 字节 MTU 算）。超出时**轮转起始位置**，让每个 NPC 平均分到发送机会（MTA 远距同步的做法）
  - 发送节拍是会话的 `sendHz`，没配置时是 33 ms，约 30 Hz（`session.cpp` 第 451–452 行）
- **插值**（`coop/element/lerp_window.h`，`npc_pose_drive.cpp`）：
  - MTA 式固定窗口线性插值：**收到包时算一次误差**（目标 − 当前），在 75 ms 窗口内线性补完，窗口结束时直接贴到目标，消除浮点漂移
  - 位移超过约 1000 cm（再加上速度 × 0.5 s）就判定为传送，直接贴过去
  - **不做外推**（推断：没看到外推代码；窗口结束后就停在目标上）
  - 依赖移动组件状态的"落地"这类边沿，从流数据里重放
- **血量和伤害**（`docs/players.md`「Vitals, damage and death」，`coop-entity-expression-map.md`「A client's hit on a parked creature」）：
  - 客户端打被停住的生物时，`addDamage` 被拦下，本地先播受击反馈，然后把"生物元素 ID + 声称的伤害 + 命中点 + 冲量"作为意图发给房主
  - 房主按发送方手上的物品、射程、视线、与该玩家最新流式瞄准方向的夹角（≤60°）判定，把伤害上限截到物品最大值，再调用生物自己的 `addDamage`。血量、死亡、销毁都由房主决定，**不回复**
  - 生物打到客户端时，房主发可靠消息 `PlayerHit`，让被打的客户端对**自己的**玩家执行同一个函数，护甲减免也由那边算
- **AI 读"本地玩家"的生物**（`owner_entity_sync`）：各端保留原生的掷骰，自己拥有自己掷出来的那只，再广播出去让别人看镜像。原因：在客户端压掉会删掉这段遭遇，放到房主掷又会锚在错误的玩家身上
- **杀人 wisp 的特殊处理**：房主那边的蓝图永远抓房主自己（它的函数写死了"主玩家"）。房主读出它真正锁定的目标；如果是客户端，就在房主这边中和这次假抓取，再给受害者发 `WispGrab`，受害者在自己的机器上按房主给的延迟真正死亡（`npcs-and-kerfur.md`「The killer wisp」）
- **销毁**：房主广播销毁；蓝图里自己销毁的角色，由房主的姿态遍历发现已死，再同样退役

### 对 VOID/BREAKER 的借鉴

- 我们的敌人 `CH_AI_Base_C` 和 Multivoid 的"房主拥有的角色"是一回事，方案可以几乎照搬：
  - **生成**：房主 hook `SpawnEnemyImmediate`、`AddEnemyPool`，或用 `NotifyOnNewObject(CH_AI_Base_C)` 分配 NetID 并广播"类 + Transform + 参数"
  - **客户端自己刷出来的**：Lua 取消不了，只能**出生即销毁**，或者从源头上关掉客户端的刷怪逻辑（见第 1 节）
  - **镜像**：客户端生成同类后，关掉 AI 控制器、移动 tick、攻击 timer
- **包结构可以参考**：44 字节的姿态条目，包括 ID、位置、yaw、速度（驱动混合）、几个可选字段和状态位。我们是快节奏 FPS，敌人动作多，建议加"当前攻击编号"（`PrimaryAttack`…`QuartinaryAttack`）作为**可靠事件**单独发，不要塞进姿态流。这也是 Geom Octa 的做法：姿态走流，"决定"走可靠事件，在镜像自己的蓝图里重放动画
- **插值**：75 ms 固定窗口 + 贴目标 + 传送阈值，实现简单，在 Lua 里也容易写。快节奏 FPS 的敌人会冲刺、瞬移，传送阈值要按我们的移动速度重新标定（推断）
- **轮转**：我们一场战斗的敌人数量可能超过 31 个，照抄"超出就轮转"即可，不需要按距离做兴趣区。Multivoid 明确"没有兴趣区裁剪，带宽只按是否活跃来限"（`scope.md` 规则 2）
- **伤害判定照抄 `hit_intent` 的形状**：客户端打敌人 → 本地立即播受击反馈 → 发意图（敌人 NetID、伤害、命中点）→ 房主做合理性检查后调用 `ApplyDamage`。对应 `sync-design.md` §4 表里的"敌人血量、死亡"。这比"客户端只走假子弹、真子弹由房主生成"更容易做到"手感立即"：房主只需要校验，不需要重新模拟弹道（推断；两种方式可以组合：假子弹负责视觉，命中作为意图上报）
- **敌人打玩家**：房主判定命中远端傀儡后，发 `PlayerHit` 让受害者执行自己的 `DealDamageToPlayer`。这和 `sync-design.md` §4 现在写的一致。另外要**取消傀儡身上的受伤入口**，防止房主的血量被扣（Multivoid 在非本地玩家身上取消三个碰撞伤害入口，`players.md`）。Lua 做不到取消，可以考虑让傀儡不接受伤害，例如 `SetCanBeDamaged(false)`（推断）

---

## 3. 物理道具、拿着和扔出去的物体

### 他们怎么做（`docs/props.md`）

- **静止时归房主**。客户端从不负责创造共享道具：
  - 客户端捡起：本地销毁 → 销毁事件发到房主 → 房主销毁自己那份，把 key "暂存"
  - 客户端放下：在 finish-spawning 时捕获本地的新生成，作为 `PropDropIntent` 发出（暂存的 key、类、Transform、速度、投掷序号），房主作为唯一作者生成，镜像再通过普通的出生广播回来
- **拿在手上时归持有者**：
  - 每帧不可靠地发送 `PropPose`，带抓取时生成的 **hold generation**（防止旧包在松手后又把道具"拿"回去，即 MTA 的 sync time context）
  - 接收方关掉物理，用**固定延迟快照插值**（渲染比最新姿态晚一个间隔）跟随
  - 第一帧姿态到达时，在接收方也执行一遍游戏的"抓取前置"（清寿命、唤醒、解冻、从墙上取下）
- **松手 / 扔出**：
  - 可靠的 `PropRelease` 带 Transform、冻结和睡眠标志、**松手瞬间的线速度和角速度**（游戏的"扔"不是冲量，而是玩家甩镜头时物理引擎累积的跟踪速度）、所关闭的 hold 和投掷序号
  - 接收方从持有者的 Transform 开始，把速度还给刚体，然后**调用道具自己的 thrown 事件**，让声音和拖尾由引擎产生
  - 流停半秒，或者换拿别的道具，算作隐式松手
- **投掷后的权威选举**：
  - 房主把投掷者选为这个道具的 syncer，给新的 generation，主动下发授权（`PropSyncAnswer`）
  - 投掷者以 drive 流发送位置、速度、时钟（`PropDrivePose`，每条 80 字节）
  - 每一行都按投掷上限截断（`coop/net/throw_bounds.h`）
  - **行数据可疑"扣信任、不扣显示"**：连续 `kMaxRefusedRows` 次失败就收回权限，房主从最后一个合格行接管
  - 投掷者离开、沉默、超时，都交还房主
- **由房主驱动的道具**（钩子拖拽、扫帚推、房主自己生成的下落物）：
  - 房主维护一个"正在运动"的集合，**只发上次以来动过的道具**
  - 停止运动半秒后，用可靠的 `PropDriveEnd` 发最终姿态、物理标志、速度，并关闭 generation
  - 最多同时 32 个在滑行，超出的各自本地下落（`coop/props/host_spawn_watcher`、`prop_drive_host`）
  - **静止判定**：房主在道具"停止移动"0.5 s 后结束流（`kRestMs`），此时刚体还没 sleep，于是各端各自安顿，实测相差 0–6.4 cm
- **接收方停住物理**：远端拥有期间设成 kinematic；游戏重新打开模拟就再锁；新镜像出生时就是 kinematic。**手上的操作永远优先**：本地玩家抓取时立刻让出，把停住时拿走的物理还回去
- **已知缺陷**（`props.md`「Known limits」）：
  - 两人同时抓同一个道具，两边都会发流，没人裁决
  - 不是"扔"、只是"放下"的道具，各端物理各自落地，**不收敛**：灭火器 14 次放下，两端相差 0.2–152.6 cm
  - 被推动的道具撞到的其他道具只在房主那边动（因为没有动作触发流）
  - 被房主驱动的道具在客户端不可抓（kinematic 的刚体抓不了）

### 对 VOID/BREAKER 的借鉴

- 对应 `phase2-04` §3D 和 `sync-design.md` 的「可移动的物理物体」：
  - **抓取**期间由持有者流式发送，带 hold generation。`phase2-04` §3D 原本设想"抓起要房主确认"，Multivoid 的经验是**先本地抓、立即流**，冲突靠 generation 和信任账本处理（他们承认双抓问题还没解决）。我们的投掷是战斗动作，延迟敏感，**建议照搬"本地先行"**
  - **扔出**时发可靠消息"Transform + 线速度和角速度 + 投掷序号"，房主把投掷者选为 syncer，由投掷者流式发送飞行轨迹，直到命中或静止，然后交还房主。命中造成的伤害和破坏仍由房主判定（`ThrowableHit` / `PrimeHit` 在房主执行），这和 `phase2-04` §3D 的方向一致
  - **静止检测**：动了才发；停止 0.5 s 后用可靠消息发最终姿态、速度，并关闭流；同时运动的上限约 32 个。这正好是 `sync-design.md` 写的"物体静止后停止发送（参考 Multivoid）"，现在有了具体参数
- **Chaos / Havok 的开关问题**（`sync-design.md` 的 ❓）：Multivoid 的做法是"远端拥有期间设成 kinematic + 游戏重新打开就再锁 + 释放时还速度 + 不往静止刚体写速度"。我们在 Lua 里用 `SetSimulatePhysics(false)`，或者 `BPI_Interact.SetSimulatePhysics`（`phase2-04` 表里有这个接口函数，正好可以用）（推断）
- **`CH_AI_Tick`（能被扔的敌人）**：先按"敌人"处理（房主权威），被抓或被扔期间按"被持有的道具"处理。Multivoid 的 kerfur 也是"角色/道具"双形态，他们给它**一个跨形态的稳定 ID，转换时就地重新绑定**（`npcs-and-kerfur.md`「The kerfur」）

---

## 4. 跨机器的物体身份：关卡里摆放的 vs 运行时生成的

### 他们怎么做

- **元素 ID**（`docs/architecture.md`「Identity」，`coop-entity-expression-map.md`「Identity ranges」）：
  - 线上 16 位，背后是 O(1) 的查找
  - **ID 空间分两半：房主从下半区分配，客户端从上半区分配**它本地创建的元素，所以两边不会撞号；有两道信任检查确认发送方只用了自己能分配的区间
  - 大部分接收端只信房主，只有"销毁"和"转换"两种消息两个区间都能发
- **出生时分配身份，不做事后普查**：曾经"被动普查时给 ID"导致每次加入产生约两千条僵尸双行。原则是"one actor is one row"（一个 Actor 只对应一行）：通过唯一的 create-or-adopt 路径（`coop/element/identity_create`）认领已知 Actor、重新绑定变形后的 Actor，遇到活着的冲突就拒绝，而不是复制一份
- **销毁再重建的过渡**（拿在手上 → 放下 → 收进背包 → 装备）要**把身份带过空档**（`coop-sync-doctrine.md` Step 5）
- **key**：
  - 道具用游戏自己的存档 key（构造脚本没有 key 时会生成一个 GUID，存档会持久化它）。mod 只读不改；唯一的例外是在接收端生成镜像、生成完成之前把房主的 key 写进去（`props.md`「Identity」）
  - 游戏对没进存档的物体**每个进程随机生成 key**，所以同一扇门在两台机器上的 key 可能不同。解决办法是**可移植身份**（`coop/element/portable_identity`）：
    - 子 Actor = 父的身份 + 组件名
    - 关卡里烘焙的 Actor = 它的对象名
    - 顶层的运行时 Actor = 它的 key
- **没有 key 的存档物体**（垃圾堆、关机的 kerfur）：按存档捕获那一刻的**精确位置**绑定到房主 ID；index→ID 的映射表已经做好，默认关闭（`join.md`「The join window」、「Known limits」）
- **按类型 + 距离的认领兜底**：出生消息里的 key 在本地找不到时，在 **30 cm 内找同类、同 `list_props` 行**的道具认领并改成线上的 key，用来处理"每端各自生成"的东西（蘑菇等）；找不到才新建（`props.md`「How a birth finds its local actor」）。注意**要排除手上物品这类"像世界道具但不是"的 Actor**
- **去重矩阵**（`coop-entity-expression-map.md`「The dupe matrix」）：把"两个入口可能表达同一个 Actor"的每一处列成表，各自写明靠什么去重。"如果两端能各自创造同一个对象，设计里必须先写清哪个是正本、另一个怎么消解"（`coop-sync-doctrine.md` Step 5）

### 对 VOID/BREAKER 的借鉴

- **关卡摆放的物体**：`sync-design.md` §2 用 UAID 名字，这和 Multivoid 的"关卡烘焙的 Actor 用对象名"完全一致，方向对。还要补上 **"子 Actor = 父 + 组件名"** 这条：我们的可破坏物 `Swap` → `SpawnGC` 之后，生成的 Geometry Collection 是运行时 Actor，名字每端都不同，要用"原物体 UAID + 角色"来命名（推断）
- **运行时生成的物体**：直接采用 **"房主下半区、客户端上半区"** 的 NetID 分区。客户端本地预测生成的东西（例如客户端自己扔出的物体副本、假子弹的命中特效需要引用的对象）就不会和房主的 ID 撞号
- **出生时分配，不做普查**：用 `NotifyOnNewObject` / hook 生成函数的时刻分配 ID，**不要每秒扫一遍世界补 ID**
- **销毁再重建过渡**：可破坏物"静态网格 → `Swap` → GC"、宝箱"关 → 开"、模组"世界里 → 背包"，都是"同一逻辑实体换了 Actor"，要像 kerfur 那样保持一个逻辑 ID，就地重新绑定
- **同一子关卡被摆两次**：`sync-design.md` 的"坐标取整到 10 cm"和 Multivoid 的"30 cm 内同类认领"、"按位置绑定"是同一类兜底。Multivoid 提醒的风险是：**位置要在快照那一刻记下来，之后不再改**；要排除玩家手上、傀儡身上的同类 Actor
- **做一张自己的去重矩阵**：例如"房主广播的敌人 vs 客户端自己 Data Layer 加载出来的预置敌人"、"房主破坏广播 vs 客户端本地力场打碎的同一个物体"，每处写明谁是正本

---

## 5. 中途加入：快照里有什么、怎么应用

### 他们怎么做（`docs/join.md`）

- **加入者从不自己生成世界**："Two copies of the game started from the same save diverge at once"（同一个存档启动的两份游戏会立刻分叉）：随机垃圾、首次运行的生成、每进程的 key 都不一样。所以加入者从**房主的实时世界**启动，只重放"捕获之后的变化"。**不重放历史，只发当前状态**
- **固定顺序**：
  1. **准入**：双向签名挑战、密码证明、分配槽位，同时检查版本对
  2. **存档传输**：房主用游戏自己的存档路径把实时世界捕获到临时槽。游戏在事件进行中会拒绝收集世界，所以他们**只在捕获这一次调用期间**拒绝游戏的"事件中"判断。然后在 Transfer 通道分块发送，由发送缓冲区的背压控制节奏。存档头前面附加"存档数组下标 → 房主元素 ID"的映射。客户端写成游戏菜单不会列出的 `zcoop_<pid>.sav`，**用游戏自己的加载器加载**，于是每个道具都由引擎放好、静止、带着房主的 key
  3. **世界之前的状态**：玩家自己的背包、生命值、站位，在世界生成之前替换进存档对象
  4. **加载和静默检测**：加载期间的销毁事件**不广播**（否则客户端加入时会按 key 把房主的道具全删掉）。等游戏的 `loadObjects` 返回之后，静默探针**每秒 5 次统计加载尾部的数量，连续不变才算稳定**；有一个绝对期限，超时会大声记录"降级"
  5. **连接重放**（客户端宣布就绪后，房主执行）：
     - **显式删除**：加入者的存档里有、房主现在没有的道具
     - **快照括号**：`SnapshotBegin`，每个活着的 keyed 道具一条 spawn（客户端按 key 认领 / 不存在就创建 / Transform 不同就收敛），`SnapshotComplete`
     - 下载窗口内房主移动过的物体的**位置修正**
     - **每个状态通道的当前状态**（约 40 类）
     - **增量种子**：在存档捕获那一刻记下内容的多重集，就绪时把差异作为追加和按哈希的删除发出去
  6. **对账和揭幕**：结束标记之后，在静默时运行 **membership sweep**，删掉房主从未认领过的本地 Actor。有两道保护：按类的完整度下限，以及**一次要删一半以上就中止**的阀门。整个过程被**全屏帷幕**挡住；所有镜像**隐藏生成**，确认之后再显示
- **加入窗口期间房主还在玩**：每一种变化都有负责人。删除靠存档差异，新增和移动靠快照括号和修正，日志类靠种子，名册变化靠世界之前的消息集合
- **"世界就绪"之前，房主只发一小批与引擎无关的消息**（名册、存档传输、背包、剧情事件）。其他发往未就绪槽位的广播**故意丢掉**，由各通道的种子补上（否则会和连接重放重复）
- **每个通道必须写明中途加入时怎么处理**，五种形状：snapshot / seed / park / **replay**（从头重放一个进行中的事件，并绕过存档里"已经发生过"的记录）/ unlatch。"别在 X 期间加入"不算答案（`architecture.md` 原则 8，`coop-sync-doctrine.md` Step 6）
- **阶段令牌**：每个阶段等待一个必须不断前进的令牌（下载字节数、快照条数、房主每秒发的 `JoinPhaseNote`）。令牌停住就以该阶段命名失败；**"活着但卡住"（同一阶段数值不变）30 s 结束**；没有全局总超时（`join.md`「A phase that stops」）
- **稳定错误码**：`MV-J*`（加入方）、`MV-H*`（房主）、`MV-T*`（传输层），退役的编号永不复用

### 对 VOID/BREAKER 的借鉴

- **最大的差异**：VOTV 是持久世界，用"传存档"作为底；我们是一局局的 roguelite，局内状态很可能不在可传的存档里（`sync-design.md` 说客户端要禁写 `LimaSaveGame.sav`）。所以我们的底应该是 **"房主的生成选择"**（`Chosen*Scenario`、Data Layer、biome、种子），这在 `sync-design.md` §1 已经定了。Multivoid 的警告正好适用：**同一个种子生成的两份世界会立刻分叉**，因此"生成选择"之后**必须**接一次快照括号和 membership sweep，不能假设两边一样（推断）
- **可以直接照搬的流程**：
  1. 准入 + 版本检查
  2. 下发生成选择 → 客户端生成关卡（**此期间客户端的销毁和破坏事件一律不广播**）
  3. 静默探针：每 0.2 s 统计关卡内 Actor 或可破坏物的数量，连续稳定才算加载完（对应我们 Data Layer 的异步流送，推断）
  4. 客户端发"世界就绪"
  5. 房主：显式删除列表（`DestroyedActors`）、**快照括号**（所有运行时 NetID 实体 + "状态 ≠ 初始"的物件）、各通道当前状态
  6. sweep 删掉房主没认领的本地运行时物体（带"超过一半就中止"的阀门）
  7. 揭幕
- 这正是 `sync-design.md` §3 L4"中途加入"的细化。`phase2-04` §3E 想复用 `BPI_SaveInterface` 的 `GatherSaveData` / `SpawnFromSave` 作为快照载体，**和 Multivoid 的做法一致**：他们对有 `getData` 的道具，把它的存档记录作为第二条消息跟在出生消息后面（`props.md`），致谢里也提到 Moddy 的"save records as spawn payloads"
- **帷幕 + 隐藏生成**：成本低、体验好，直接采用
- **进行中的事件要从头重放**：例如加入时正在 boss 战或某个 Scenario 事件里，需要"重放 + 跳过已发生标志"的处理

---

## 6. 消息和协议设计

### 他们怎么做

- **数量**（`protocol.h`，已清点）：`ReliableKind` 有 **196** 个枚举值；`MsgType` 除了 `Reliable` 和 `VoiceFrame`，还有 13 个不可靠流：
  - 玩家：`PoseSnapshot`、`PropPose`、`RagdollPose`、`HandPose`
  - 房主下发的批量：`EntityPose`、`WorldActorPose`、`TrashCarryPose`、`PropDrivePose`
  - 设备和世界：`DeskCursorPose`、`ClockPose`、`DeskSimPose`、`DishPose`、`ReelPose`
  - 不可靠流是"新的覆盖旧的"（按包头 seq）；语音另走带抖动缓冲的流
- **包头**（`protocol.h` 的 `PacketHeader`，20 字节）：magic "VMTP"、`kProtocolVersion`（当前 264，就是"版本对"里的构建号）、类型、originContext（房主转发时给槽位"这一次占用"的编号）、每个发送方单调递增的 seq、**senderEpoch**（每个进程生成一次，防止重连之后旧进程的包被采纳）、senderSlot（房主转发时改写）、**stateTimeMs24**（**状态的**产生时间而不是发送时间，"否则游戏线程卡一下就会把旧位置配上新时间戳"）
- **大小**：可靠 payload 限一个数据报（`kMaxReliablePayload = 256 − 20 − 8 = 228` 字节），超出的走 bulk sink 或 Transfer 通道。姿态批量按 1400 MTU 算条数
- **格式**：packed little-endian POD 结构直接发（"两端都是 x86-64 Windows"），每个结构都有 `static_assert` 校验大小。**没有通用压缩**，只做针对性量化：生命、饥饿、睡眠各 1 字节，状态位，可选字段用标志位
- **语义化**："The wire format is semantic: names, keys and positions, never engine addresses"（线上只传名字、key、位置，从不传引擎地址）（`architecture.md`）
- **规则**：退役的编号永不复用（文件里列着 16、17、21…）；每个消息的方向、信任、中途加入处理写在定义旁边
- **三条可靠通道**（`session_lanes.h`，`architecture.md`）：
  - **High**：不指向任何元素的消息，比如链路探测、加入信标、恢复生命值
  - **Default**：所有指向元素或世界的消息，**统一放在一条有序通道上**，保证"生成"一定排在"指向它的状态"前面
  - **Transfer**：存档流
  - 和 MTA 不同：MTA 把爆炸、伤害放在高优先级；他们放回 Default，因为一条通道同时决定顺序和优先级
- **转发白名单**：只有列出的消息房主会转发给其他客户端（`IsClientRelayableReliableKind`）
- **路由**：`coop/dispatch/` 下一个 drain + 8 个按族划分的路由器（entity、state、signal、intent、economy、prop_drive、world、container_act）。CI 里的 `reliablekind_gate.py` 检查"每个消息类型都有接收方，或者说明为什么没有"："a kind that parses but does not route is a silent black hole"（能解析但没被路由的消息是无声的黑洞）（`coop-sync-doctrine.md` Step 7）
- **可靠发送不丢**：要么进流，要么进每条通道的 backlog，要么连接断开，**从不"警告一下然后丢掉"**（`send_backlog`）
- **带宽控制**（`docs/send-path.md`）：GNS 自己不估带宽，他们自己测"送达字节 / 在途时间"，每秒做 10 次决定（刹车 / 爬升 / 死区 / 锚定）；连接以 145 KB/s 起步，3 s 内能爬到上限；可靠消息给不可靠流和探测包预留 64 KB；单个槽位的队列不超过 2 s
- **版本**（`docs/versioning.md`，`join.md`）：
  - **版本对** = (游戏目标版本, 构建号)，**逐字节相等**才能一起玩
  - 检查三次：浏览器列表里标成琥珀色、加入握手时拒绝、包头作为最后一道防线
  - 另外读取运行中游戏的 **exe 链接时间戳 + 主 pak 索引哈希**来识别游戏构建：未知构建只警告、不禁止；两端游戏构建不同则拒绝
  - 官方签名构建和改过的构建不能混着玩（可以开开关放行）
  - 更新检查只提示，不强制
  - 所有和版本相关的知识集中在两个文件：6 个签名、约 40 个引擎偏移、约 30 个蓝图偏移、约 200 个内容名
  - **字节码指纹**（`bytecode-fingerprint.md`）：把每个被 hook 的蓝图函数的字节码规范化后取哈希，与参考表比对，能发现"名字没变、逻辑变了"的游戏更新；每个被 hook 的函数都要登记一行（`UE_FACT_FN`），否则注册不了

### 对 VOID/BREAKER 的借鉴

- **规模参照**：一个成熟的 VOTV mod 有 196 种可靠消息。我们第一版有 30–50 种就够了，但从第一天就该定下这些规矩：
  - 一个文件定义所有消息类型
  - 编号永不复用
  - 每个消息旁边写明方向、信任、中途加入处理
  - 改了线上格式就升协议号
  - 开一个"能解析但没有处理函数"的自检（Lua 里在启动时遍历消息表、检查 handler 表就行）
- **包头字段**：建议照抄 `seq` + `senderEpoch` + `stateTime`（状态产生的时间）+ 原始槽位。在星形拓扑下，房主转发客户端的包时改写槽位，接收方按槽位路由
- **SteamCore / Steam P2P 的映射**（推断）：Steam 的 `SendMessageToUser` / `SendP2PPacket` 有 reliable / unreliable 和 channel。可以用 **channel 0 = 不可靠流，1 = High 可靠，2 = Default 有序可靠（所有指向实体的消息），3 = Transfer**。**一定要让"生成"和"指向该实体的状态"走同一条有序通道**，这是 Multivoid 特别强调的。要先查 SteamCore 插件暴露出来的 Blueprint 节点有没有 channel 参数
- **不需要通用压缩**：快照里的位置用 float，生命值量化成 1 字节，可选字段用标志位就够了。Lua 序列化可以用 `string.pack`（Lua 5.3+；UE4SS 内置的是 5.4，推断）
- **版本检查**：握手时带 (VOID/BREAKER build 号, mod 协议号)。VOID/BREAKER 的 build 号我们已经有了（`23764881`）。字节码指纹的思路很值得借：UE4SS Lua 也能拿到 `UFunction`，但读 `Script` 字节数组可能要靠反射偏移（推断）。**简化版**：启动时对每个要 hook 的函数做一次"存在性 + 参数签名"检查，失败就把这条通道标为不可用，并写进报告

---

## 7. 玩家表现：远端模型、动画、名牌、语音

### 他们怎么做（`docs/players.md`，`docs/voice-and-chat.md`）

- **傀儡**：生成游戏自己的玩家类 `mainPlayer_C` 作为**没有控制器的孤儿**：
  - 关掉自动 possess 和 AI 控制器
  - 去掉只属于本地画面的系统（后处理、麦克风、第一人称手臂）
  - 清空 game-mode 指针
  - **关掉 Actor tick 和移动组件 tick**（否则整套单机逻辑会跑起来，改掉全局相机状态）
  - 每个 tick 由 mod 把流里的速度和移动模式写进移动组件，动画蓝图读这些字段，**走跑动画和腿部 IK 由引擎自己算**
  - "有没有控制器"是全代码里区分"本地玩家 / 傀儡"的唯一判据
- **姿态包**（`PoseSnapshot`，32 字节）：位置、yaw、pitch、头相对身体的 yaw 差、水平速度、状态位（在空中 / 布娃娃 / 着火）、生命 / 饥饿 / 睡眠各 1 字节。插值和 NPC 一样，是 75 ms 窗口
- **接收方补出**第一人称游戏本来不产生的东西：
  - 原地转身：站着时身体不动、头先转，超出范围身体才跟上
  - **脚步声**：复刻游戏的步幅累计器，再调用游戏自己的脚步函数
- **接收端不校验移动**：游戏有 10 处会传送玩家，都发生在客户端自己的进程里，所以位移不连续只记进"移动信任账本"，不影响显示
- **布娃娃**：状态位打开时生成游戏的布娃娃身体，隐藏傀儡网格，让骨盆速度跟随流
- **手持物**：作为"玩家状态"而不是世界实体。本端轮询，变化时广播类名，对方挂一个只用于显示、关掉物理和碰撞的镜像在傀儡的武器组件上
- **名牌**：mod 自己的叠加层把傀儡头部投影到屏幕上画昵称、ping、血条，随距离淡出。**房主统一分配显示名**（重名加数字）；比较按"看起来是否一样"（字体缺字都折叠成同一个哨兵字符）
- **皮肤**：在游戏自己的骨架上换网格；没有对应 pak 的人看到默认身体，**不从别人那里下载**
- **语音**：
  - 复用同一个连接，没有第二个端口
  - 48 kHz 单声道，20 ms 一帧 Opus，带 FEC（前向纠错）
  - 按住 G 说话，或者按音量阈值触发
  - 经房主不可靠转发，带序号
  - 接收端：每个槽位一个抖动缓冲，静音后预缓冲约 100 ms
  - 线性距离衰减 + 垂直方向淡出 + 立体声声像；悄悄话半径减半；范围由房主设置
  - 墙体不会让声音变闷
- **文字聊天**：客户端的一行是意图，房主给它分配单调递增的序号后统一广播（因为转发发生在网络线程，没有地方能保证顺序）

### 对 VOID/BREAKER 的借鉴

- 我们的"幽灵傀儡"已经验证过显示（`sync-design.md` §4）。值得补的有：
  - 用游戏自己的 `CH_LimaCharacter_C`（或者只用它的 mesh + 动画蓝图）作为傀儡，**关掉 tick、关掉移动组件 tick，每帧手动写速度和移动模式**，让动画蓝图自己算动画（推断：要看我们的动画蓝图读哪些字段）
  - 状态位扩展成我们的动作：在空中、滑铲、跑墙、钩爪、滑索、冲刺（Dash）、近战中（对应 `phase2-04` §3A）
  - 手持武器用"类名 + 配件"作为状态同步，挂到傀儡手上，只用于显示
- **接收端不校验移动**：我们有钩爪、冲刺、传送器，一样适用
- **语音**：我们走 Steam，可以优先看 SteamCore 有没有暴露 Steam Voice（`GetVoice` / `DecompressVoice`），没有的话再说（推断）。Multivoid 的参数（20 ms 一帧、约 100 ms 预缓冲、线性衰减、房主设置范围）可以作为默认值
- 名牌在 Lua 里可以用 UMG `WidgetComponent` 挂在傀儡头上（推断），不需要自己写 overlay

---

## 8. 存档：房主 vs 客户端

### 他们怎么做（`docs/join.md`「Leaving and rejoining」，`docs/players.md`「Inventory」）

- **只有房主能存档**：
  - 客户端在引擎唯一的写入点上用原生 detour 取消世界存档写入（`coop/save/save_block`）
  - 暂停菜单的存档按钮变灰（`save_button_disable`）
  - 房主开会话前**先备份存档目录**（游戏是原地写入，没有别的恢复办法，`save_guard`）
- 客户端加入时用的存档写成 `zcoop_<pid>.sav`，会话期间保留，断开时删除，启动时清掉超过一小时的残留
- **全局进度文件从不传输**
- **每个玩家的资料**（背包、生命值、站位）由房主按玩家身份分存档保存，**只在房主自己存档时一起写盘**。原因：资料比世界新会导致物品重复，比世界旧会导致物品丢失
- 回来的玩家拿回自己的东西，出现在上次站的位置；死了离开的重新开始
- 首次加入时给的三件起始物品用新 key 复制（否则会和原物品别名）

### 对 VOID/BREAKER 的借鉴

- `sync-design.md` §4 已经写了"客户端必须禁止写入局内存档（hook `GI.SaveGameData`）"。Multivoid 补充了三件事：
  1. **禁写要在最底层的写入点**，不能只拦 UI 按钮。Lua 取消不了，可以在 `SaveGameData` / `SaveGameToSlot` 之前把目标槽名换掉，或者写完立刻从备份恢复（推断，要验证）
  2. **房主开局前备份**
  3. **客户端的全局进度**（解锁、货币、Meta 进度）要不要累计是个设计问题。Multivoid 的答案是"全局进度文件从不传、客户端从不存"。我们的 roguelite 有 Meta 进度，可能要"客户端局内不写，局末由房主下发奖励，客户端写自己的 Meta"（推断，需要讨论）
- "资料和世界一起写盘"的原则对我们是：**局末结算**才写各自的 Meta 存档，避免中途掉线把半局的状态写进去

---

## 9. AI 辅助开发的工作流规则

### 他们怎么做

- 公开说明：作者负责方向、架构、测试和发布决定，大量代码由 Claude 写（`README.md`「Credits」：Claude 有 1,367 个 commit）。作者原话的意思是：用不好 AI，问题在流程或工具；"document everything, every session"（每次会话都记录所有东西）
- **三条底线**（`CONTRIBUTING.md`「Ground rules」）：
  1. **不拄拐杖**：在根因处修，禁止在症状处加过滤、skip-if、suppress-X、catch-and-ignore
  2. **不留迁移包袱**：替换时同一个提交删掉旧代码，不留"先保留"的旧实现，不留重新启用旧行为的开关
  3. 自己的底层：不导入 UE4SS 符号
- **八条架构原则**（`architecture.md`）：
  1. 不改游戏文件
  2. 做成引擎扩展层，而不是一堆 hook
  3. 平行类层级：`RemotePlayer` 持有网络状态，引擎的 Pawn 负责渲染和动画
  4. 定点修崩溃，不做大范围压制（"一个大过滤器上线一周就撤了"）
  5. **`scope.md` 是什么要同步的"法律"**
  6. 增强单机，不替换单机
  7. 两层两棵目录树
  8. 必须支持中途加入
- **证据标签**（`docs/README.md`，`CONTRIBUTING.md`）：每个行为声明都带 `[V]`（实测，附引用：日志行 / 反汇编 / 文件和行号）、`[RD]`（逆向推导，没看到实际运行）、`[?]`（没验证）。"A doc that says something works without naming its evidence is a bug in the doc"（文档说某件事能用却不给证据，是文档的 bug）
- **逆向要"数清楚"**（`coop-sync-doctrine.md` Step 1）：设计之前要列出：
  - 状态的**所有写入者**（搜索加阅读，不只看第一个结果）
  - 所有动作及其调用方式（dispatch opcode）
  - 跨端重要的读取者
  - 出生和死亡的入口
  - 哪些进存档
  - "If a hook 'should fire', prove that it fires with a probe before building on it"：说某个 hook"应该会触发"，先用探针证明它会触发，再在上面建东西
- **逆向工具阶梯**（`docs/re-workflow.md`）：反射和转储 → 反汇编 → UE4SS 现场探针（Live View、函数调用器、F8 对象转储、F7 头文件转储、Lua 探针）。蓝图控制流**只从字节码反编译和控制流图读**，不从头文件推断。四份游戏副本：房主 / 客户端 1 / 客户端 2 / 开发用；开发副本带 UE4SS 的 GUI 和 Lua mod，**不要假设开发副本上能用的在玩家副本上也能用**
- **"六个陷阱"**（`coop-dispatch-visibility.md`），对 Lua 也适用：
  - 调用返回 true 不代表真的有效果（static 组件会忽略移动和换网格）
  - 用"非代表性的入口"驱动实体会得到假结论（直接调用抓取函数，和玩家按键走的不是同一个槽位）
  - hook 解析的是"实例会执行的那个函数"，不是"类声明的那个函数"（基类 / 子类覆盖）
  - 反编译输出里的"死循环 goto"其实是 VM 的执行流栈，要看控制流图
  - **停住 tick ≠ 停住 Actor**：别的事件仍然能改世界
  - 周期性调用一个"刷新"函数，可能顺带写坏玩家状态
- **测试**（`docs/testing.md`，`CONTRIBUTING.md`）：
  - 一台机器上开 2–4 份游戏，一个启动器负责部署、启动、跑场景
  - **smoke**：房主 + 客户端稳态 ≥30 s，采样内存，两份日志里**不能有 mod 的 Warn 或 Error**，**不能有超出设计频率的重复日志**
  - `smoke4`：1 房主 + 3 客户端，在每个客户端日志里找"为另一个客户端生成了傀儡"，证明房主转发链路
  - **并发测试**：`ctakerace` 让房主和客户端在同一个 GO 屏障（未来时间戳的哨兵文件）同时拿同一件物品，结果 1 = 正确，2 = 复制，0 = 丢失；先跑 control 模式（只有房主拿），结果必须是 1
  - 游戏内 harness：场景从文件或环境变量读取，机器人**向游戏要寻路**走过去，不合成输入
  - 结论写成日志里的一行，用日志断言判定（例如垃圾堆循环在两端日志上的 13 条不变式）
  - 每个检测器或 gate **先证明它会变红**才信任；差分证据优于绝对证据，并带负对照（`coop-sync-doctrine.md` Step 8）
  - 大量 `coop/dev/*_drill`（388 个文件），包括 hostile drill：模拟恶意客户端发伪造消息，统计房主的拒绝
- **提交和文档形状**：
  - 提交格式 `[scope] 祈使句摘要`，正文 ≤12 行，**附一行证据**（测了什么、结果如何）
  - 文件 <800 行，一个功能一个文件
  - 每个子系统文档用同一个骨架：*Purpose · How it works · Who owns what · Wire messages · Late join · Known limits · Code map*，<300 行
  - 文档和代码同一个提交更新；不写日记、不引用对话
  - **工作笔记、逆向日志、会话记录放在仓库外**：用 `.gitignore` 白名单发布 docs，小写文件名 = 公开，全大写 = 本地；有一个"会话收尾脚本"（`[docs] close:`）
  - CI 有一堆 gate：提交信息、公开文档的散文规则、可靠消息路由、泄漏检查等
- **"新增同步通道"检查表**（`docs/code-map.md`「Adding a sync lane」）：
  1. 定所有者
  2. 在 protocol 里加消息类型并升协议号
  3. 在路由器里路由
  4. 一个文件负责这条通道，**中途加入的处理写在同一个文件里**
  5. 更新子系统文档；有可能自动化的，加一个 dev drill

### 对 VOID/BREAKER 的借鉴

- **建议采用的规则**：
  - 证据标签 `[V]` / `[RD]` / `[?]`：我们已经在用 ❓ 和"推断"，统一成三档就行
  - **"每个通道一行"的 `status.md` 表**：系统 / 同步了什么 / 所有者 / 中途加入处理 / 状态（works / tested / built）。不报百分比
  - **`scope.md` 作为"法律"**：同步什么、明确不同步什么（例如碎片、火花、伤害数字），新东西先按规则归类再写代码
  - **子系统文档统一骨架**（Purpose … Known limits）
  - "先证明 hook 会触发"：VBTrace 探针正是做这个的，以后**每条通道都先挂探针，看到计数再写同步代码**
  - **smoke 判据**：两端日志里没有 mod 的 Warn 或 Error，没有超出设计频率的重复日志，≥30 s
  - **并发屏障测试**（同一时刻抢同一个宝箱或拾取物，结果相加 = 1）
  - **先证明 gate 会变红**
  - 会话笔记放在不公开的目录，公开文档只描述当前状态
- **测试环境**：两份 VOID/BREAKER 能不能在一台机器上同时运行？要先测（Multivoid 的 feasibility 第一个问题就是"游戏是不是单实例"）。Steam 版通常不能同一个账号开两份，可能需要两台机器或两个账号（推断）
- **对 Claude 的要求**：写进项目的 CLAUDE.md 或 CONTRIBUTING：
  - 不拄拐杖
  - 不留旧实现
  - 修根因的提交要写"停住前后有几个作者"
  - 先列状态的所有写入者再设计

---

## 10. 他们记录的坑、缺陷和局限

摘自各页的「Known limits」和相关段落：

- **事件不能"只传存档"**：游戏在事件进行中拒绝收集世界，他们只好在捕获期间临时绕过"事件中"判断，代价是房主的存档对象会被写成"事件中途"的状态（`join.md` §2）
- **同一存档启动的两份世界会立刻分叉**：所以不能各自生成（`join.md`）
- **被动普查给 ID 产生过约两千条僵尸双行**（`coop-entity-expression-map.md`）
- **大范围过滤器上线一周就撤了**（`architecture.md` 原则 4）
- **接收端拦截**会把防作弊变成丢数据（`architecture.md`）
- **停住 tick 停不住 ubergraph**：钩子镜像加载时仍然会建一个真的 PhysX constraint（`coop-dispatch-visibility.md`「Six traps」）
- **周期性调用一个刷新函数**把玩家的 `lookAtComponent` 清空，导致每 333 ms 重建一次交互按钮（同上）
- **基类和子类函数解析错误**：客户端清洁器本地删了一年的道具，6 种污渍用错了材质（同上）
- **双抓**：两人同时抓同一个道具没有裁决；"放下"的道具不收敛，最大偏差 152.6 cm；被推动的道具撞到的其他道具只在房主那边动；被房主驱动的道具在客户端不可抓（`props.md`）
- **一些道具会自己累计变化**（混凝土干燥、食物腐烂），各端会漂移。只有磁带做了每秒一次的纠正器（`props.md`「Props that change on their own」）。解决思路是三种之一：停住大脑由房主驱动 / 房主纠正器 / **锚点**（只存开始时间戳，各端自己算，只在速率恒定时有效）
- **NPC**：kerfur 的部分动作没同步；只有一种跟踪类生物按端拥有；**9 类环境刷怪器既不镜像也不禁止**，所以每端各长各的鹿和树（`npcs-and-kerfur.md`）
- **随机**：好几种稀有掷骰仍然各端各掷；黑雾没有通道；触发体积的事件各端各自触发（这是设计如此）（`events-and-weather.md`）
- **加入**：
  - 静默探针有绝对期限，超时会带着"降级"进入世界
  - 加入窗口内的变化会在帷幕揭开后突然出现
  - sweep 碰到"一半"阀门会中止，留下多余的道具
  - 没有 key 的存档物体靠位置匹配（`join.md`）
- **带宽**：GNS 不估带宽，初始速率只按 ping 估一次；曾经的 1 MiB/s 全局下限在窄上行链路上造成 71% 丢包；两个可靠控制律因为"参照物会被自己的队列污染"被否掉（`send-path.md`）
- **玩家**：复活后会水平漂移，原因没查清；别的机器上傀儡受到的伤害按设计丢弃（`players.md`）
- **语音**：墙不让声音变闷；没有降噪（`voice-and-chat.md`）
- **测试**：机器人只走脚本，"手感"要靠人判断；只有容器抢夺有并发屏障场景（`testing.md`）
- **status 表的老实话**："Most mechanic-level facets sit at `built`"（大部分机制层面还只是"建好了、没跑过"）；信号工作站的通道多数只是 built，而真正玩过的那些已知问题最多（`status.md`）

### 对 VOID/BREAKER 的借鉴

- 我们最可能踩的同类坑：
  1. Data Layer / Scenario 生成两端不一样（"同一种子"分叉）
  2. 关掉客户端敌人 tick 后，敌人蓝图的事件、委托仍然在改世界（"停住 tick ≠ 停住 Actor"）
  3. 基类和子类覆盖：hook `BP_PreDestructibleItem_Master_C.DestroyObject`，子类覆盖了没触发，或者反过来
  4. 周期性调用游戏的"刷新"函数（例如 UI、HUD 更新）顺带改了玩家状态
  5. 时停（`FreezeTime`）这种全局效果没有对应物。Multivoid 的"不允许暂停"是最简单的答案，值得当默认值（`sync-design.md` 设计问题 1）

---

## 优先级：最该采用的 10 条

1. **所有权表 + "压产生者，不在接收端拦"**：客户端所有共享结果（刷怪、掉落、伤害、破坏、随机）一律不在本地产生，只发"做什么"的意图；房主可以作弊，检查只对客户端。写成 `docs/sync-design.md` §1 的正式规则（来源：`architecture.md`「Who owns what」）
2. **在 Lua 里实现"停住大脑"的三种方式**，作为"取消"的替代：停调度（关 tick、清 timer、停 AI 逻辑）、字段锁存（`InteractEnabled?` 一类）、物理 kinematic；做不到时出生即销毁，或事后对账。每个停住都写注释："停住前后各有几个作者"（来源：`coop-sync-doctrine.md` Step 4）
3. **一张集中的刷怪器 / 随机源禁用表**（`spawn_authority` 式）：类名、函数或 tick、原因、是否故意保留，由一个 Lua 模块统一管理（来源：`npcs-and-kerfur.md`）
4. **NetID 分区 + 出生时分配 + 一个 Actor 只对应一行**：房主下半区、客户端上半区；只在生成入口分配，禁止普查补 ID；销毁再重建的过渡（可破坏物 `Swap`、宝箱、模组进背包）带同一个逻辑 ID；做一张去重矩阵（来源：`coop-entity-expression-map.md`）
5. **一条"生成 + 实体状态"共用的有序可靠通道**，另开 High（探测、信标）和 Transfer（大快照）；包头带 `seq`、`senderEpoch`、**状态产生时间**、原始槽位（来源：`session_lanes.h`，`protocol.h` 的 `PacketHeader`）
6. **中途加入流水线**：生成选择 → 客户端生成期间不广播 → 静默探针（每 0.2 s 统计，连续稳定）→ 世界就绪 → 显式删除 + 快照括号 + 各通道当前状态 → sweep（带"超过一半就中止"的阀门）→ 帷幕揭开。每条通道在自己的文件里写明 snapshot / seed / park / replay / unlatch 中的哪一种（来源：`join.md`）
7. **敌人同步模板**：44 字节姿态批量（约 30 Hz，超过 31 条就轮转）+ 75 ms 固定窗口线性插值 + 传送阈值；攻击和决定作为可靠事件在镜像自己的蓝图里重放；客户端打敌人走 `hit_intent` 式的意图并由房主校验；敌人打玩家用 `PlayerHit` 让受害者自己扣血（来源：`npc_pose_host.cpp`、`lerp_window.h`、`players.md`）
8. **投掷物模板**：拿着时由持有者每帧流 + hold generation；松手时可靠发送 Transform 和线速度、角速度 + 投掷序号；房主把投掷者选为 syncer；行数据可疑"扣信任不扣显示"；停止 0.5 s 后由房主发结束边沿并关闭流，同时滑行上限约 32 个（来源：`props.md`）
9. **文档和证据纪律**：`[V]` / `[RD]` / `[?]` 三档标签；`status.md` 每个通道一行（所有者 / 中途加入 / 状态，不报百分比）；`scope.md` 作为"法律"；子系统文档用 Purpose … Known limits … Code map 的统一骨架；会话笔记放在不公开的目录（来源：`CONTRIBUTING.md`，`docs/README.md`）
10. **测试判据**：先用探针证明 hook 会触发（VBTrace），再写同步；smoke 至少 30 s，两端日志里没有 mod 的 Warn 或 Error、没有异常频率的重复日志；对拾取、开箱做"同一时刻抢"的屏障测试（结果相加必须 = 1，并先跑 control）；每个检测器先证明会变红（来源：`testing.md`，`coop-sync-doctrine.md` Step 8）

另外两条不进前十，但值得记下：
- 版本对逐字节相等 + 启动时检查每个 hook 目标是否存在（`versioning.md`、`bytecode-fingerprint.md`）
- 房主在 hook 掉自身的"服务对象"问题上用 `served_player` 替身（`npcs-and-kerfur.md`）
