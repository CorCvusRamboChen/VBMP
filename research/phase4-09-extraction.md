# Phase 4-09：撤离任务（插数据块、守点）的联机同步（0.12.0）

2026-11-13，build 26439385。代码 `src/lua/VBMP/Scripts/mission.lua`（`MISSION` 30 的代码 3、4、6）。

## 用户报告

真实联机（客户端 Ramboooo，房主 richdog，B02）："那个守护的，把东西塞到一个里面的那个"：
- 客户端插了数据块，站在区域里，自己那份开始并完成了；
- 房主那份显示还没开始。

客户端日志：`BP_Mission_Extraction_C started here, telling the host`（03:54:24）；房主 83 秒后才完成。

## 调查方法

测试存档（B05）里没有撤离任务。10 个红色区域里只有风暴、冰冻、强化、过载据点和刷波任务；richdog 的世界已被测试覆盖。

所以用脚本在 B05 生成一套：
- `BP_Mission_Extraction_C`（`/Game/ProjectLima/Blueprints/AI/Waves/`）
- `BP_Extraction_DataBank_C`、`BP_Extraction_DataCube_C`（`/Game/ProjectLima/Blueprints/GameplayObjectives/Extraction/`）

再 hook 全部相关函数，记录调用顺序。

## 发现

- **初始化**：`InitiateCountdown` → `FindBankAndCube` → `SetupMission` → `ShowTutorial`。
  - 任务自己找到数据库和数据块，三者的 `DataBankRef` / `DataCubeRef` / `MasterMission` 互相引用。
  - 玩家离得太远（70 米）时不初始化，引用一直为空、倒计时不走；35 米时会初始化。
  - 同一个世界里生成第二套，会关联不上。
- **数据库会被挪位置**：生成在任务位置，初始化后被挪到别处，房主和客户端挪到的位置不同（相差 3.5–9 米）。
  - 这只确认了手动生成的情况；真实关卡里是不是也这样不知道。
- **插数据块**：数据块进入数据库的 4 号感应盒后，依次调用：
  1. `DataBank.CubeOverlapped(cube, 4)`（感应盒碰到任何东西都会调用，非常频繁）
  2. `DataBank.StartDefence` → `StartShieldAnimation`
  3. `Mission.StartingDefence` → `StartExtractionTimer` → `StartSpawner`
  4. `Cube.ReleaseAndDestroy`
- **上传**：
  - 只有 `Mission."PlayerInZone?"` 为真时，`TimerEvent` 才推进 `CurrentPercent`（约每秒 2.5%）。
  - 进出区域时游戏调用 `PlayerInZone` / `PlayerNotInZone`。
  - 真正算"区域"的是 `DataBank.UploadSphere`（半径 3000，中心偏离数据库原点），不是 `Mission.MissionSphere`（半径 7637）。
- **人不在区域时**：脚本调用 `PlayerInZone()` 也能让上传继续（82.5% → 100%）。
  - 到 100% 后依次调用 `UploadFinished` → `RemoveShieldAnimation` → `MissionCompleted` → `TimerCompleted`，`Completed?` 变为真。
- **`PlayerInZone` 不是幂等的**：每调用一次就多一个计时器。
  - 我们替他调用一次，他自己走进来时游戏再调用一次，上传就变成双倍速度（12 秒从 12.5% 到 85%）。
  - 先调 `PlayerNotInZone` 再调 `PlayerInZone`，就恢复成一个计时器。
- **失败**：`CountdownTimerRemaining`（50–75 秒）走完、还没插数据块，任务就失败。
  - 失败时游戏也会调用 `StrongholdCompleted`，而 `Failed?` 是在这之后才设为真。
  - 所以原来的"完成"同步会把房主的失败当成成功发给客户端，客户端按成功结算、发奖励。
- **客户端崩溃**：客户端那份插入数据块后自己开始刷怪；客户端按"敌人只在房主"的规则删掉刚刷出的敌人，游戏随即访问违例崩溃（空指针）。
  - 普通据点删本地敌人没有出过事，撤离任务不行。
  - `StopSpawner()` 停掉客户端那份的刷怪后不再崩。
- **传送不可靠**：用 `K2_SetActorLocation` 传送玩家时，区域的进出事件不一定触发。

## 同步方案

两个方向都同步，按任务位置配对（类名 + 坐标取整到 100）。

| 代码 | 方向 | 发送 | 接收 |
|---|---|---|---|
| 3 数据块插入 | 双向 | hook `DataBank.StartDefence`，取 `MasterMission` | 自己那份的数据库调用 `CubeOverlapped(自己的数据块, 4)`；数据块已经没了就调用 `StartDefence()`；客户端随即 `StopSpawner()` |
| 4 我在区域里 | 双向，每秒一次 | 自己的玩家到 `DataBank.UploadSphere` 中心的距离 ≤ 半径 | 3 秒内收到过，就保持 `PlayerInZone`（没开就调用一次，记为"替他开着"）；不再收到、自己的人也不在，就调用 `PlayerNotInZone` |
| 6 失败 | 房主 → 客户端 | 完成 hook 延后 0.5 秒，看 `Failed?` 再决定发 2 还是 6 | 调用 `StrongholdFailed()` |
| 2 完成 | 房主 → 客户端 | 不变 | 不变 |

另外两条规则：
- 游戏自己的 `PlayerInZone`（hook）在"替他开着"时触发，下一次检查时改成"关一次、开一次"，只留一个计时器。
- 客户端那份插入数据块、开始防守后，调用 `StopSpawner()`。

## 自测（双开，A 房主、B 客户端，两边同一位置各生成一套）

| 时间 | 情况 | A | B |
|---|---|---|---|
| 6.5 秒 | B 进区域并插入数据块，A 在 82 米外 | 12.5%，跟着上传 | 15% |
| 17.7 秒 | A 进区域，B 出去 | 40% | 42.5%，跟着上传 |
| 27–34 秒 | 两人都在外面 | 停在 47.5% | 停在 52.5% |
| 60 秒 | A 回到区域 | 100%，成功 | 100%，成功（B 人在外面） |

- 上传速度正常（每秒约 2.5%），没有崩溃。
- 失败测试：A 先生成、倒计时先到 → A 失败 → B 收到"失败"后也失败（B 自己还剩 22 秒），没有按成功结算。

## 没确认 / 已知限制

- 真实关卡里的撤离任务还没测过：数据块是不是关卡摆好的、数据库会不会被挪位置。
- 如果两边的数据库位置不同，画面上两人站的地方会对不上，同步本身不受影响。
- 一个人拿着数据块走的过程（`PickedUpThrowable` / 投掷）不同步，只同步"插进去"这一下。
