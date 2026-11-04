# Phase 0 / 01 — 安装目录与主程序静态探测

- 日期：2026-11-03
- 机器：gaming PC `DESKTOP-CBAJBFJ`（192.168.1.197，连接方式见 Serena 全局记忆 `gaming-pc-desktop-cbajbfj`）
- 方法：只读脚本 `research/scripts/vb_probe.ps1`、`research/scripts/vb_strings.ps1`，经 scp + ssh 在游戏电脑上运行，没有修改任何游戏文件
- 注意：1.0 正式版 2026-11-04 上线，以下结论只对下面这个 build 有效

## 版本

| 项 | 值 |
|---|---|
| 平台 | Steam，appid `2615540` |
| 安装路径 | `C:\D\steamapps\common\VOIDBREAKER` |
| Steam buildid | `23764881`（LastUpdated 2026-11-03 08:58 UTC） |
| 主程序 | `VOIDBREAKER\Binaries\Win64\VOIDBREAKER-Win64-Shipping.exe`，173.7 MB，单体构建 |
| 构建标识 | `++ProjectLimaDepot+Main-CL-4091`（内部代号 ProjectLima，开发商自己的分支，不是官方 `++UE5+Release-5.x`） |
| 引擎版本 | **未确定**。pak v12、IoStore TOC v8、含 Iris 网络模块，推断 ≥ UE 5.4。需要 UE4SS 启动日志确认 |

## 打包与加密

- `VOIDBREAKER-Windows.pak`（493 MB）：pak v12，**索引已加密**（encryptedIndex=1）
- `VOIDBREAKER-Windows.utoc/.ucas`（10.5 GB）：IoStore，**加密**（ContainerFlags=11 = Compressed|Encrypted|Indexed）
- `global.utoc/.ucas`：未加密
- 加密密钥 GUID 全为 0，即单一默认 AES 密钥 → 要从主程序里提取 AES 密钥后才能用 FModel 浏览资源
- **AES 密钥和解包出来的资源一律不得提交到仓库**

### AES 密钥（2026-11-03 已提取，build 23764881）

- 脚本：`research/scripts/vb_aeskey.ps1`。纯静态扫描主程序，没有运行游戏，也没有下载第三方工具
- 前几种模式都没命中：`mov [rcx+N], imm32`（10 个候选）、SSE/movabs（7492 个）、高熵 32 字节窗口（221 万个）。**命中的是栈上局部数组写法**：任意基址寄存器、任意起始偏移的 8 条连续 `mov dword [base+disp], imm32`，候选 2250 个
- 验证方法：用候选密钥做 AES-256-ECB 解密 pak 索引的第一个块，得到 FString 挂载点长度 10，内容为 `../../../`
- PE 节表正常，没有 `.bind` 节 → **没有 SteamStub 加壳**
- 存放位置：**只放在 gaming PC 的 `%USERPROFILE%\vbmp\aes_key.txt`**，SHA-256 指纹前缀 `00108620`。不要写进仓库、文档或聊天
- IoStore 容器的 key GUID 也是全 0，应该是同一把密钥，用 FModel 打开时顺便确认
- 1.0 更新后重新跑这个脚本；如果指纹变了，说明密钥被换了

## 反作弊与已有注入

- 没有 EasyAntiCheat、BattlEye、EOS 反作弊的文件
- 没有 UE4SS 或 dwmapi/xinput 代理 DLL，是干净安装
- 游戏电脑上装有腾讯 ACE 驱动，但只有 Mecha BREAK Demo 使用，与本游戏无关

## 第三方模块（与联机相关）

- `steam_api64.dll`（Steamworks v161）+ 主程序内含 `OnlineSubsystemSteam` → **可以直接使用 Steam 大厅和 SteamNetworkingSockets 的中继打洞**，不需要像 Multivoid 那样自建主服务器和 TURN
- 主程序内含 `IpNetDriver`、`GameNetDriver`、`NetDriverDefinitions`、Iris → UE 自带的网络栈被编译进去了。游戏本身是单机，蓝图和 Actor 大概率没有设置复制，所以只能作为备选路线评估
- FMOD Studio：音频走 FMOD，不走 UE 音频
- msquic、DLSS、Streamline（Reflex/帧生成）：与联机无关

## 破坏系统线索（只能说明代码被编译进去，不能证明游戏用它做破坏）

- `GeometryCollection` 289 处、`ChaosDestructionEvent`/`UChaosDestructionListener`、`FractureEngine` → Chaos 破坏系统存在
- `GeometryScript` 789 处、`DynamicMesh` 286 处 → 运行时网格编辑（布尔切割之类）也存在
- 如果破坏实际上是用 DynamicMesh 布尔运算做的，同步可以做成"房主广播切割事件（位置/形状/尺寸），客户端用同样参数重放"，比同步 Chaos 碎片简单得多。**这是 Phase 0 下一步最需要确认的事**

## 下一步

1. 在游戏电脑上装 UE4SS（需要你在电脑前启动一次游戏），拿到：确切的 UE 版本、对象/类转储（CXXHeaderDump、UHT 头文件）、.usmap
2. ~~从主程序提取 AES 密钥~~（已完成，见上）→ FModel 查看资源，确认：玩家有没有第三人称身体模型、破坏用的是 GeometryCollection 还是 DynamicMesh、关卡生成用的种子/RNG 类
3. 1.0 更新后重跑 `vb_probe.ps1`，对比 buildid 和结构变化
