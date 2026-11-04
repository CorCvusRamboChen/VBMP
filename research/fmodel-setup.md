# FModel 设置（gaming PC）

- 程序：`C:\Users\User\vbmp\tools\FModel-nov-2026\FModel.exe`
  - 来源：github.com/4sval/FModel 的 `nov-2026` 正式版
  - SHA-256 `209bef15…7de1`，与 GitHub 给出的一致
  - 没有代码签名（FModel 一向如此），首次运行时 SmartScreen 可能拦一下，点"仍要运行"
- 下载脚本：`research/scripts/vb_get_fmodel.ps1`
- 运行环境：.NET 8 桌面运行时，gaming PC 已经装了

## 第一次打开

1. **Directory Selector** 窗口 → 点 "Add undetected game"
   - Name：`VOIDBREAKER`
   - Directory：`C:\D\steamapps\common\VOIDBREAKER`
   - UE Versions：先选 **GAME_UE5_4**。如果加载时报错或文件树是空的，依次试 `GAME_UE5_5`、`GAME_UE5_6`
2. 确定后会弹出 **AES Manager**，也可以从菜单 Directory → AES 打开
   - 用记事本打开 `C:\Users\User\vbmp\aes_key.txt`，把那一行 `0x…` 整行复制到 Main Static Key
   - 点 OK
3. 左侧 **Archives** 标签：全选后点 Load
   - `VOIDBREAKER-Windows.utoc` 的状态如果变成可加载，就说明 IoStore 确实也是这把密钥
4. 切到 **Folders** 标签就能看到资源树

## 映射文件（2026-11-04 已有）

- 引擎已确认是 **UE 5.7**：UE Versions 选 `GAME_UE5_7`
- `.usmap` 已经由 UE4SS 生成：`C:\Users\User\vbmp\dumps\23764881-20261104-024205\VOIDBREAKER-5.7.4-4091+++ProjectLimaDepot+Main-1ceefac8.usmap`
- 在 Settings → General → 勾选 Mapping File / Local Mapping File，填上面的路径，重启 FModel 后就能看到资源属性
- 1.0 更新后需要重新转储，换成新的 `.usmap`

## 这次要找什么（截图或抄下路径就行）

1. **Content 下的顶层文件夹**：展开 `VOIDBREAKER/Content` 第一层，截一张图
2. **玩家**：找名字里带 Player / Character / FirstPerson / Arms 的文件夹。看里面有没有完整身体的 SkeletalMesh（`SK_` 开头），还是只有手臂（Arms / FP）
3. **破坏**：在 FModel 顶部搜索框（或按 Ctrl+Shift+F）搜 `GC_`、`GeometryCollection`、`Fracture`、`DynamicMesh`、`Destruct`，记下命中的数量和所在文件夹
4. **关卡生成**：搜 `PCG`、`Seed`、`Room`、`Generator`、`LevelGen`，以及 `Maps` 文件夹里有哪些 `.umap`

任何资源都不要导出到项目目录或仓库里，只记录路径和名字。
