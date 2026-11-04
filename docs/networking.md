# 网络层（Phase 2，VBMP mod build 1）

## 传输：Steam P2P，纯 Lua

- 游戏自带商城插件 **SteamCore**，它把 Steam API 包成了蓝图函数，UE4SS 的 Lua 可以直接调用。所以不需要编译 C++，也不需要自建服务器：
  - `UNetworking`（旧版 ISteamNetworking P2P）：`SendP2PPacket`、`IsP2PPacketAvailable`、`ReadP2PPacket`、`AcceptP2PSessionWithUser`、`AllowP2PPacketRelay`。全部是同步函数，适合每帧轮询
  - 走 Steam 的中继（SDR），自带 NAT 穿透
- UE4SS 调用规则（来自 RE-UE4SS 源码 `LuaUObject.cpp` 的 `call_ufunction_from_lua`）：
  - 参数个数必须完全匹配
  - 输出参数传一个表：标量写回 `t[参数名]`，数组和结构体直接填进这个表
  - `TArray<uint8>` 可以直接传 Lua 数字表
- `FSteamID` 在反射里是黑盒（8 字节，没有字段）。用 `USteamUtilities.MakeSteamID(字符串)` / `BreakSteamID(FSteamID)` 和字符串互相转换。`ReadP2PPacket` 输出的远端 ID 读不出来，所以**每个包的包头自带发送者的 SteamID64**
- 只用通道 0。状态包用 `UnreliableNoDelay`，事件包用 `Reliable`
- 实现：`src/lua/VBMP/Scripts/transport.lua`（另有 loopback 传输，在同一个进程里延迟 2 秒把包送回来，用于单机测试）

## 发现和连接：Steam 好友 + 富状态

- 房主：`UFriends.SetRichPresence("vbmp", "host")`
- 客户端：`SetRichPresence("vbmp", "client")`，然后遍历好友（`GetFriendCount`/`GetFriendByIndex`，标志 `Immediate = 3`），找到 `GetFriendRichPresence(好友, "vbmp") == "host"` 的人，把他当作房主
- 旧版 P2P 会把陌生人的包扣住，直到对方调用 `AcceptP2PSessionWithUser`。所以房主每 2 秒扫描一次好友，对富状态是 `client` 的人调用 accept
- 也可以在 `Saved\VBMP.ini` 里写 `host=<SteamID64>` 直接指定房主
- 前提：双方是 Steam 好友，并且都在运行 VOID/BREAKER（富状态只对同一款游戏里的好友可见）

## 协议（`codec.lua`）

包头 `"<c2BBi8"`：魔数 `VB`、协议版本（1）、消息类型、发送者 SteamID64。

| 类型 | 方向 | 内容 | 通道 |
|---|---|---|---|
| HELLO | 客户端 → 房主 | mod build、玩家名 | 可靠，每秒重发，直到收到 WELCOME，30 秒后放弃 |
| WELCOME | 房主 → 客户端 | 房主名 | 可靠 |
| REJECT | 房主 → 客户端 | 原因（mod build 不一致） | 可靠 |
| STATE | 任意 | 发送方时钟、x/y/z、yaw、pitch、flags | 不可靠，30 Hz |
| LEVEL | 任意 | 持久关卡名 | 可靠，变化时立刻发 + 每 5 秒重发 |
| PING/PONG | 任意 | 时钟 | 不可靠，每 2 秒，用于测延迟 |
| BYE | 任意 | — | 可靠 |

- 星形拓扑：客户端只和房主通信；房主把客户端的 STATE/LEVEL 原样转发给其他客户端（包头里保留原发送者）
- 10 秒没收到某人的包就当作掉线
- 远端玩家：`puppets.lua`，按本地接收时间戳缓存，延后 120 ms 插值显示；不在同一关卡就隐藏；名字牌朝向本地相机
- 房主那边的傀儡额外带 `WorldPartitionStreamingSourceComponent`（保持远端玩家周围的关卡加载）和导航生成器（`NavigationSystemV1.RegisterNavigationInvoker`）

## 控制

- 热键：Ctrl+Shift+H 开房 / J 加入 / L 离开 / G 本机回环
- VBTools 背包面板的"联机"区：两个 mod 的 Lua 状态互相独立，所以 VBMP 每秒把状态写进 `Saved\VBMP_status.txt`，并读取 `Saved\VBMP_cmd.txt` 里的命令
- 每次开房或加入前，自动把存档备份到 `Saved\VBMP_backup_<模式>_<时间>.sav`

## 已知限制（Phase 2）

- 只同步位置；世界、敌人、破坏、战斗还是各自独立的
- 傀儡没有动画（小白人保持 A 字姿势滑行）
- 只校验 mod build，不校验游戏 build
- 默认名字牌用 ASCII；Steam 昵称里有中文时，`TextRenderComponent` 的字体可能显示成方块
