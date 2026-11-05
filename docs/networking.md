# 网络层

## 默认：Steam P2P 辅助进程（2026-11-05 起，0.4.0）

- `src/lua/VBMP/steam/vbmp-steam.ps1`（PowerShell 内嵌 C#）。开房 / 加入时由 main.lua 用 `os.execute('start … -WindowStyle Hidden')` 启动，不用玩家手动运行
- 它在独立进程里设置 `SteamAppId=2615540`（appmanifest），加载游戏自带的 `Engine\Binaries\ThirdParty\Steamworks\Steamv161\Win64\steam_api64.dll`，用真正的 64 位 SteamID 收发旧版 ISteamNetworking P2P 包（全部可靠通道）
- 接口来源：DLL 导出表（1089 个导出，含 `SteamAPI_SteamUser_v023`、`SteamAPI_SteamFriends_v017`、`SteamAPI_SteamNetworking_v006`、`SteamAPI_ManualDispatch_*`；DLL 里的接口版本字符串 `SteamUser023`/`SteamFriends017`/`SteamNetworking006`），参数签名对照 Steamworks.NET 自动生成的 NativeMethods.cs
- 和游戏之间用通道文件交换（与 TCP 桥接相同）：房主写 `VBMP_link_A2B.bin`，客户端写 `VBMP_link_B2A.bin`
- 发现：房主 rich presence `vbmp=host`，客户端 `vbmp=client`；客户端在好友里找 `host`，找不到时如果只有一个好友在玩 VOID/BREAKER 就连他；`VBMP.ini` 的 `host=<SteamID64>` 可以直接指定
- 房主用手动回调分发处理 `P2PSessionRequest_t`（1202），只接受好友（`GetFriendRelationship` = 3）；只接一个队友
- 生命周期：`Saved\VBMP_steam_session.txt` 写着 `<role> <token>`；内容变了、文件没了或游戏进程退出，辅助进程就退出（清掉 rich presence）。状态写 `VBMP_steam_status.txt`，日志写 `VBMP_steam.log`
- 自测（2026-11-05，gaming PC，同一个 Steam 账号）：
  - 不开游戏时探测：初始化成功，SteamID 17 位，好友 86，rich presence 写入后能读回，给自己发的 P2P 包收到了
  - 游戏运行时开房：辅助进程和游戏同时初始化 Steam 没有冲突，游戏里显示 "Steam：等待好友加入"
  - 离开 → 辅助进程退出；加入 → 显示 "没有找到开房的好友"；关游戏 → 辅助进程退出
  - **没测**：两个账号之间真正连上（需要第二个 Steam 账号）
- 备用：`VBMP.ini` 写 `transport=bridge` 改走下面的 TCP 桥接

## 备用：文件通道 + TCP 桥接（0.3.1；0.4.0 起需要 `transport=bridge`）

**Steam P2P 从 Lua 用不了**（2026-11-05 自测，build 26439385，实例 A 由 Steam 启动）：
- SteamCore 的 `FSteamID` 是 8 字节、没有反射字段的结构体（CXXHeaderDump `SteamCore.hpp`：`struct FSteamID {}; // Size: 0x8`）
- UE4SS 把它返回成**空的 Lua 表**，再传回去时按字段填，所以是全 0。实测：
  - `User.GetSteamID()` → `BreakSteamID` 得到 `"0"`
  - `MakeSteamID("76561197960265729")` → `BreakSteamID` 也是 `"0"`
  - 好友 `GetFriendByIndex(0)` → `GetFriendPersonaName` 得到空串
  - `SendP2PPacket` 返回 false
- 不带 `FSteamID` 的调用正常：`GetPersonaName`、`GetFriendCount`（86）、`SetRichPresence`
- 所以下面"Steam P2P"一节的设计不能用；代码留着（命令 `steamhost`/`steamjoin`），作为以后做 C++ 或蓝图 mod 时的参考

**替代方案**：
- 双开测试已经验证过的 `localfile` 通道：两个只追加的帧文件 `VBMP_link_A2B.bin`（房主写）/ `VBMP_link_B2A.bin`（客户端写），帧 = 2 字节小端长度 + 内容
- 每台电脑运行 `tools/dist/vbmp-bridge.ps1`（PowerShell 里内嵌 C#）：
  - 把本机写出的完整帧通过 TCP 发给对方，把收到的完整帧追加进本机的接收文件
  - 房主监听 TCP 27777（IPv4/IPv6 双栈），客户端去连；断线后自动重连
  - 连接时跳到发送文件里最后一个完整帧的边界：旧包不补发，流不会错位
- 命令 `host`/`join`（热键 Ctrl+Shift+H/J、面板按钮）走这个通道；`lanhost`/`lanjoin` 仍是同机双开、不经过桥接
- 同机测试桥接：实例 B 的通道文件放在 `Saved\VBMP_B\`，用 `tools/remote/bridge_pair.ps1` 在 gaming PC 上起一对桥接（127.0.0.1）
- 只支持 2 人
- 连通性靠玩家自己解决：同一局域网；虚拟局域网（Tailscale / ZeroTier / Radmin VPN）；或者端口转发
- Windows 防火墙默认挡住入站（2026-11-05 实测：笔记本连 gaming PC 的 27777 超时）。房主要运行 `firewall-allow.bat`，或在弹窗里点允许
- TCP 自带可靠和有序，所以 `reliable` 标志在这条通道上没有作用；丢包时会有短暂卡顿

---

# 旧设计：Steam P2P（Phase 2，VBMP mod build 1；从 Lua 用不了，见上）

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
