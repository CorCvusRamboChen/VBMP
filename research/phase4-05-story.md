# Phase 4.5 — 剧情 / 对话同步

- 日期：2026-11-05，build 26439385（Biome_05 的存档）
- 来源：CXXHeaderDump（build 23764881）、UE4SS 对象转储、游戏内实测

## 剧情怎么开始播放

- 关卡里的剧情和对话放在"序列容器"Actor 里，字段 `SequenceToPlay : ULevelSequence*`、`SequenceObject : ULevelSequencePlayer*`，部分有 `Triggered?`（一次性）
  - 类：`/Game/ProjectLima/Blueprints/Gameplay/Triggers/BP_SequenceContainer`、`_NormalUse`、`_Dialogue`，`/Cinematics/BP_SequenceContainer_RandomTable`，`/Audio/BP_TriggerDialogueSequence`
  - 都实现开关接口：`Switch(bool On?)`、`Activate(bool Activate?)`、`InstantSwitchAndLock(bool)`、`SwitchLuckType(...)`（拉杆、开关、触发器共用这一套）
- 触发链（Biome_05 实测列出）：`BP_PlayerTrigger_C`（`Box` 重叠，`OutputSignals` 数组）→ `BP_SignalOps_DoOnce_C` → 容器 `Switch(true)`
- 这一关的容器：`LS_0500_Entrance`、`LS_0500_Address`（名字带 `_Dialogue_` 但类是 `BP_SequenceContainer_C`）、`LS_0501_SpireExplode`、`LS_B05_Start_SpireAlreadyDestroyed`（NormalUse）
- 从脚本调用容器的 `Switch(true)`：播放 `LS_0500_Entrance`（1473 语音 + 字幕 + 特效），原生 `MovieSceneSequencePlayer:Play` 的 hook 也看到了
- 原生 `/Script/MovieScene.MovieSceneSequencePlayer:Play` 可以 hook（每段序列播放都会经过），`GetSequence()` 拿到序列名；目前只当诊断用
- 语音台词还有一条路：`BFL_VOSequences.PlayDialogueSequence(LevelSequence, Type, WorldContext)`（拾取、终端等个人事件），没同步

## 没弄清的

- 用 `K2_SetActorLocation`（带 sweep）把角色移过触发器的方框没有触发重叠事件，所以"真实走进触发器 → 容器 Switch"这一步没在实测里看到，只是按触发链推断
- boss 竞技场 / boss 传送门的过场（`BP_BossFightArena_Master`、`BP_BossTeleporter`）走的不是这些容器，没处理
