# VBMP — VOID/BREAKER 联机 mod

《VOID/BREAKER》（Stubby Games / Playstack）的非官方 2 人合作联机 mod，基于 [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) 的 Lua 脚本。
An unofficial two-player co-op mod for VOID/BREAKER, built on UE4SS Lua. Not affiliated with or endorsed by Stubby Games or Playstack.

## 安装

1. 从 [Releases](../../releases/latest) 下载最新的 `VBMP-x.y.z.zip`
2. 关掉游戏，把压缩包完整解压，双击 `install.bat`（自动找到 Steam 里的游戏）
3. 正常从 Steam 启动游戏。之后每次启动会自动检查新版本，下载后重启游戏生效

两个人都要安装同一个版本，并且互为 Steam 好友。详细说明见压缩包里的 `README.txt`。

## 怎么玩

- 房主：主菜单中间的"VBMP 联机"面板 → [继续并开房]
- 朋友：同一个面板里，在"开房中的 Steam 好友"里点房主旁边的 [加入]

朋友进入房主正在玩的那一局，带着自己的角色、武器和模组；离开后回到自己的存档，联机中得到的局外成长会带回去。

## 现在同步了什么

敌人（房主计算，分仇恨）、子弹和伤害、场景破坏、宝箱 / 开关 / 拉杆、剧情和对话、区域推进、据点和竞技场、倒地和复活、时停、敌人掉落（每人一份）、区域之间的地形。完整的问题清单和状态见 [docs/coop-issues.md](docs/coop-issues.md)、[docs/status.md](docs/status.md)。

## 开发

- `src/lua/VBMP/`：联机 mod；`src/lua/VBMP/steam/`：Steam P2P 辅助进程和自动更新
- `src/lua/VBTools/`：单机工具（背包里的面板）
- `docs/`：设计、规则、问题清单；`research/`：逆向调查记录
- 仓库里不包含任何游戏文件、解包资源或密钥
