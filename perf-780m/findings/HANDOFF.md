# 780M PQ2_0 Prefill 优化 — 交接 / 状态文档

> 恢复工作时的第一读本。配套：`ledger.md`（台账）、`E1-gemm-profile.md`（GEMM 发现）、
> `docs/superpowers/specs/2026-10-17-780m-pq2-prefill-design.md`（设计）、
> `docs/superpowers/plans/2026-10-17-780m-pq2-prefill.md`（计划）。

## 目标与验收
- 目标：Bonsai PQ2_0 在 780M 上 prefill 从 ~520 t/s 推向 **1000 t/s 上限目标**（1.9×），decode 不回归，输出质量不退化。
- 里程碑：M1 ≥1.15×（≈600）→ M2 ≥1.55×（≈800）→ M3 ≥1.83×（≈950）→ M4 ≥1.90×（≈1000）。
- 判定协议：同会话交错 A/B、ABBA 顺序、4 轮取中位数、相对官方二进制倍数；锚不健康（pp2048<480）的会话只记方向。
- 正确性门：ppl Δ≤1%（基准 7.7526）+ 6 条固定 prompt 逐字对照（允许微小数值漂移，实现必须正确）。
- 工作纪律：只在 `perf/780m-pq2` 本地提交（trailer `Assisted-by: DeepSeek V4.1 Flash`）；**绝不推送**；每个实验一个提交；先正确性后性能。

## 关键路径
| 项 | 路径 |
|---|---|
| worktree（工作区） | `C:\Users\31940\.local\share\opencode\worktree\05b616\780m-pq2`（分支 perf/780m-pq2） |
| 主克隆 | `D:\LLM\Backend\src\llama.cpp-prism`（origin=lingyezhixing/llama.cpp-prism，upstream=PrismML-Eng） |
| 官方锚（只读） | `D:\LLM\Backend\llama.cpp-prism-vulkan`（b10777-e3de715） |
| 构建输出 | `D:\LLM\Backend\builds\{e3de715, tip, dev, probe, probe-ssm, probe-rms, release}`（lean 构建的 exe 在 `bin\`，mirror 构建在 `bin\Release\`；-RefDir/-CandDir 要指到 exe 所在目录；`probe` = 当前采纳栈，`probe-ssm`/`probe-rms` = 过程快照） |
| 运行目录 | `D:\LLM\Backend\llama.cpp-prism-vk-perf`（scripts/ data/ builds/ logs/ reports/） |
| 模型 | `E:\models\LLM\GGUF\Ternary-Bonsai-2-4B-PQ2_0.gguf` |
| 工具链 | VS2022 + CMake 4.4.3 + Ninja 1.13.2 + Vulkan SDK 1.4.313.2（同官方 CI） |

## 常用命令
```powershell
# 构建（worktree 源码 -> D:\LLM\Backend\builds\<name>）
D:\LLM\Backend\llama.cpp-prism-vk-perf\scripts\build-vk.bat dev lean    # 迭代用（~4min 增量）
D:\LLM\Backend\llama.cpp-prism-vk-perf\scripts\build-vk.bat <n> mirror # 与官方同旗标（发布用）

# 交错 A/B（full: pp512/2048+tg128；-Quick 冒烟）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\LLM\Backend\llama.cpp-prism-vk-perf\scripts\bench-ab.ps1 `
  -RefDir <ref dir> -CandDir <cand dir>

# 正确性（ppl + 6 prompts）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\LLM\Backend\llama.cpp-prism-vk-perf\scripts\correctness.ps1 `
  -RefDir <ref dir> -CandDir <cand dir>

# 实验开关（dev 构建内建）
#   GGML_VK_PERF_BK64_OFF=1    关闭 BK=64（对照）
#   GGML_VK_PQ2_DEBUG=1        打印每个 pq2_0 GEMM 的 pipeline 名/wg_denoms
#   GGML_VK_CONCAT_DEBUG=1     打印 GDN concat 的维度/步幅
```

## 现状（截至本文件撰写，2026-10-18 06:45）
- 基线：tip `0082ac24a`（b10782）+ 已采纳优化栈。
- **已采纳优化（按时间序）**：① tip rebase（+3.0~3.6%）② quant M-slot BK=64（`8de1e148a`）③ E5 寄存器预取流水线（`cd5d6a4f8`，+1.8%）④ CONCAT 转置物化 `ggml_cont`（`fe6e1e8da`，+5.2%）⑤ **RMS/L2 短行小工作组**（`387f3638f`，vs dev：pp512 1.0507 / pp2048 1.0444 / tg 1.0037；ppl Δ=0、6/6 逐字一致）。
- **对官方（M1 直接测量，2026-10-17 21:20，全量 A/B）**：**pp512 1.1194 / pp2048 1.1094 / tg128 0.9992**；正确性全绿。**M1（1.15×）差 ~2.7pp。**
- **对官方（M1 跨线测量，2026-10-18 01:57，含 RMS/L2，安静机器）**：**pp512 1.1795（546.05→644.07）/ pp2048 1.1532（546.69→630.47）/ tg128 1.0001**。**M1 已跨线**（M2=1.55×≈800 待 GEMM 深水区）。
- **对官方（今晚终测，2026-10-18 03:43，8 轮，E5A+ + SSM_CONV）**：**pp512 1.1883（557.30→662.23）/ pp2048 1.1764（552.29→649.70）/ tg128 0.9989**；该二进制正确性全绿（ppl Δ=0、6/6）。采纳栈现为 ①-⑤ + ⑥ **E5A+**（`d51442c2c`：去掉 B 侧寄存器预取，+2.2%/+2.0%）+ ⑦ **SSM_CONV LDS 分段**（`31986a1bb`：nc==4 路径合并加载，+0.3~1.8%）。
- **凌晨续战（2026-10-18 04:00-06:30）**：再采两项——⑧ **融合转置拼接**（`7e45d6509`：concat 内 32×33 LDS 转置路径替代 GDN conv 输入的 cont 物化，实测 +0.57%/+0.68%）+ ⑨ **RMS 行缓存**（`a5c0d0c7f`：f32 共享缓存消掉 norm 的第二次全局读，逐位一致）。
- **对官方（最终，2026-10-18 05:57，前台 8 轮，健康）：pp512 1.2029（540.99→650.74）/ pp2048 1.1885（536.23→637.30）/ tg128 1.0132**；该栈正确性：ppl Δ=0、6/6 逐字一致。夜总账：1.1795 → 1.2029（pp512，+2.0pp）。
- **午后 GEMM 结构攻坚（2026-10-18 14:20-15:30）**：脏探针三连（P1 去 LDS 读 +12~15% / P2 去生产侧 +13%，其中 B≈8、A≈5 / P3 去屏障 +14%），全部候选攻击（R1a/R1b/PAD/reshape/R4' B双缓/R9 warp私有）逐一实测，仅 ⑩ **R1a 采纳**（`07c6de565`：MMA 每 k 步批量 tile 装载；8 轮 A/B pp512 **1.0284** / pp2048 **1.0270** / tg128 0.9975；位精确）。三静脉墙图见 `GEMM-attack.md`（驱动峭壁 / L2 带宽 / VGPR 悬崖）。**现累计 ≈ 1.2371 / 1.2206（按 1.2029×1.0284 / 1.1885×1.0270 折算）**。
- **收尾认证（2026-10-18 15:27）**：`builds\release\bin\Release` 重建为 R1a 态后，对官方锚正确性 **ppl Δ=0、6/6 逐字一致** ✓。
- **wave32 突破（2026-10-18 15:30-16:00）**：用户提出"多槽并发"问题 → 分析后锁定唯一真实杠杆 = **把 coopmat M 槽从 wave64 改到 wave32**（每 WG 寄存器占用减半 → 每 CU 驻留 WG 数 2→≈3；且 wave32 是 WMMA 原生宽度）。vulkaninfo 确认本机 min subgroup=32 + VK_EXT_subgroup_size_control → 机制可行；实现（host-only）：m-slot warptile {BLOCK 128→64, WARP 64→32} + `required_subgroup_size=32`（用 warptile 的 WARP 字段自守卫，只有 spec WARP==32 的管线被强制，杜绝其他 quant/f16 管线错配）。**⑪ 采纳并提交 `1dd2af0c1`**。证据：env 切换 ABBA 8 跑 **1.0450**；跨二进制 4 轮 **1.0628**（pp512）；pp2048 6 跑 **1.0385**；正确性位精确（对 R1a 态 ppl Δ=0、6/6）。wave32 下重扫：PAD 4≈8 喉点（0-6 崩 −29%）、tile 变体 cfg1 −6.1%/cfg2 −0.6%、**R1b 软流水重测 1.0004（中性 → 关闭：wave32 的多驻留已天然完成其使命）**。
- **新 standing（2026-10-18 16:02，对官方，quick 4 轮 + pp2048 6 跑）**：**pp512 1.2816（545.5→699.2）/ pp2048 1.2690（540.8→686.3）/ tg32 1.007**。
- **分支整理（2026-10-18 16:25）**：历史压缩为 3 个逻辑提交 + 1 个文档提交（明细存档 `archive/perf-780m-detail`）；死代码/调试打印/过程注释清理完毕，重建后位精确、性能持平。
- **小项尝试与回退（2026-10-18 17:30-17:50）**：⑫ sigmoid+mul 融合 与 ⑬ add+rms+mul 三连融合 均已**实现并位精确验证**（画像 −1.94ms 与 −2.0ms/pass），但合计仅 ~+0.5%，需引入 ~250 行核心融合机制改动——**按复杂度/收益比主动回退（用户决策）**，分支回到本行之前的 wave32 终态。两笔提交保存在 `archive/perf-780m-fusions`（@ `a1349138c`），如未来需要可随时复活。
- **最终 standing（2026-10-18 16:02 实测，wave32 终态）**：**pp512 1.2816（545.5→699.2）/ pp2048 1.2690（540.8→686.3）/ tg32 1.007**。
- **合并收尾（2026-10-18 18:25）**：`perf/780m-pq2` 已快进并入 `master`（= `2cbe1ad48`，与认证 tip 逐位一致；master 一并追平 prism 上游的 166 个提交）。worktree 与功能分支已清理；归档分支保留（`archive/perf-780m-detail`、`archive/perf-780m-fusions`）；`builds\probe` + `builds\release` 为终态产物。提交历史已整理为 3 个逻辑提交（整理前状态：`archive/master-pretidy`）。**至此本次战役完全归档、会话终结。**
- **两条大线侦察判定（2026-10-18 15:45，用户授权可止损）**：线 1 硬件计数器（RGP 未装；按战役证据仅剩确认性收益，无新杠杆）→ 跳过；线 2 非 coopmat 内核族（`GGML_VK_DISABLE_COOPMAT=1` 实测基线 **460.5 vs 675-678**，起点 −32%，且 ALU 管线与全部旁路工作竞争、天花板论证为负 EV）→ 不做。
- **发布 parity 构建（mirror）**：`builds\release\bin\Release`（2026-10-18 06:30 重建，含 ⑥-⑨ 全部采纳项）；对官方锚正确性 **ppl Δ=0、6/6 逐字一致**。（勘误：本行早前的 1.1851/1.1752 属于 ⑥⑦ 时代版本；⑧⑨ 后的官方口径以最终里程碑 1.2029/1.1885 为准。）
- 更早 M0 测量（仅 BK64 时代）：pp512 +7.1% / pp2048 +5.3%（跨会话绝对值有漂移，以同会话比值为准）。
- T7 画像：pq2_0 GEMM ≈ 602ms/pass。**最新画像（2026-10-18，采纳栈）**：`reports/raw/perf-probe-e5a-ssm.txt` + `reports/raw/perf-probe-concat-fused.txt`（GEMM 585.5 / GLU 39.7 / GDN 37.2 / FWHT 31.8 / CONT 25.9→9.5（融合后） / SSM_CONV 25.0 / ADD 16.5 / CONCAT 14.8→23.8（融合后，含转置工作）/ MUL 12.3 / RMS(2560,512) 11.5 / FA 8.7 / MUL_MAT_VEC f32 8.9 / RMS(128,32) 7.6 / L2 7.5 / …）。
- **教训（spec 常量）**：shader 不要用与默认值不同的特化常量（glslc 优化按默认值折叠/展开 + `local_size_x_id` 双重嫌疑）——改用 gen 编译期变体。实验代码存档 `archive/rms-spec-const-attempt`（`3a75589e3`）。
- **教训（寄存器悬崖）**：PQ2_0 M-slot shader 对 VGPR 极敏感——+16 寄存器 ≈ **-2.3%**，-16 ≈ +2.2%（BN2 / E5A+ 证据；E3-A 的 u16 载入因 ALU 增量吃掉收益，-1.1%）。A 路径对逐 idx 位操作敏感（打包/解包代价 ≥ 加载收益）。
- **教训（多槽位陷阱）**：pq2_0 coopmat 同一 SPV 在 m/s/l 槽特化中共享代码（BM/BK/BLOCK_SIZE 由 spec 常量分化）——guard 内一切映射必须从 spec 常量推导，绝不能硬编码 m 槽维度（E3-A 曾因此污染 s 槽 LDS → 短 prompt prefill 出垃圾 → KV 缓存中毒 → decode 退化为重复 token；ppl 却全绿，因为 ppl 只走 m 槽）。**短 prompt 逐字对照是这类 bug 的唯一防线。**
- 惰性管线编译：`ggml_vk_load_shaders` 每次懒编译都会重跑——创建后修改（如 wg_denoms）必须幂等（曾出现 wg_denoms 每轮翻倍的 bug）。
- **算子布局契约**：GGML_OP_SSM_CONV 隐性要求 `src0->nb[0] == sizeof(float)`（token 轴连续）——CPU 实现断言、vulkan 实现静默出错。**给算子喂跨步视图前先查它的 CPU 实现的断言**；`llama-completion -ngl 0` 是布局 bug 的快速语义预言机。
- **工具链陷阱**：PowerShell `Set-Content -Encoding utf8` 会加 UTF-8 BOM → glslc 报假错 `#version requires 420`；shader 源只可用 edit 工具改（或 `[IO.File]::WriteAllText` + `UTF8Encoding($false)`）。
- 测量漂移：同会话内也能出现 ±4% 的慢漂移；小效应（<2%）必须 **-Rounds 8**；**以 reports/raw 的逐轮 CSV 为准，不以通知摘要为准**（曾遇摘要与文件不符）。

## 关键发现（代码 + 实测）
1. **PQ2_0 prefill 路径**：coopmat1 `mul_mm.comp`，运行变体实证为 `matmul_pq2_0_f32_f16acc_aligned_m`（f16 累加 + M-tile + aligned）。M-tile 参数：BM=64 BN=64 BK=32(现 64) WM=64 WN=32 TM=TN=TK=16 WARP=64；网格 (m/64, n/64)；**A 侧解包冗余 = n/BN = 8×**。
2. **L-tile 死路**：上游因 AMD 专有驱动禁用（`ggml-vulkan.cpp:7038`）；强制开启实测 **-94%**。
3. **驱动悬崖**：coopmat tile 放大（L、BN=128）都会 **-90%+** 崩溃式变慢（LLPC 代码生成问题，怀疑展开/寄存器）；tile 维度只有 BK 可用（已吃到 +3.6%）。
4. 解包代码：`mul_mm_funcs.glsl:196`（DATA_A_PQ2_0），~4 ops/元素；B 侧 f32→f16 转换冗余已在 P3 证伪（B 侧仅 0.7% of pass，**勿优化**）；**A 侧 prep 12.3%**（+ 后续所有 A 侧变体实验的边界结论见"实验记录"）。
4b. **GEMM 利用率重估（2026-10-18 06:45 更正）**：780M fp16 峰值 ≈ **16.6 TFLOPS**（12 CU × 128 lane × 2 MAC/周期 @2.7GHz，打包 f16；RDNA3 WMMA 走同一速率）。每 pass GEMM 计算量 ≈ **3.56 TFLOP**（62×9216×2560×512 等逐项加总），当前 GEMM 585ms → **6.26 TFLOPS ≈ 38%**（负载频率下修后 ~42-46%）。P4 的"MMA 忙碌 26%"与此自洽：**瓶颈是数据通路/发射，不是矩阵单元**。→ 见下文"GEMM 结构攻坚"。
5. Debug 构建（GGML_VULKAN_DEBUG）运行崩溃（0xC0000005，shmem 检查循环处）——**不要用 dev-debug**；用 release dev + `PQ2DBG` 环境打印替代。
6. 非 GEMM 算子：**CONCAT 已修复**（根因=transpose 视图的 32× 扇区放大；修复=图内 `ggml_cont` → tiled `copy_transpose_32` 内核，+5.2%）；**RMS_NORM/L2_NORM 已修复**（+5.1%，compile-time BLOCK_SIZE 变体 + 按 ne0 派发）。剩余大项：GLU 37ms（**已判定纯带宽受限，勿动**）/ GDN 36ms / MUL_RESHAPE(FWHT) 29ms / SSM_CONV 22ms；ADD/MUL/CONT 已接近带宽极限。

## 实验记录（全部）
| # | 改动 | 结果 | 判定 |
|---|---|---|---|
| E2a-1 | 强制 L-tile | 34.7 vs 549.6 t/s（-94%） | 负，已回退 |
| E2a-2 | M-slot BN=128 | 51.6 vs ~530 t/s（-90%） | 负，已回退 |
| E2a-3 | M-slot BK=64 | 549.0 vs 529.7（+3.6%），输出一致 | **采纳（默认开）** |
| 全量 | dev(BK64) vs tip | pp512 1.064 / pp2048 1.031 / tg 0.995；正确性全绿 | **通过，保留** |
| P4/P2/P1/P3 | 相位隔离探针（MMA/A/B） | MMA 26% / A 12.3% / B 0.7%（of pass） | 定位 E5 方向 |
| E5 | 寄存器预取流水线（mul_mm PQ2_0） | pp512 1.0177；正确性全绿 | **采纳（`cd5d6a4f8`）** |
| CONCAT | transpose 物化 `ggml_cont`（delta-net） | pp512 1.0516；正确性全绿 | **采纳（`fe6e1e8da`）** |
| M1 | official vs dev（E5+CONCAT） | pp512 1.1194 / pp2048 1.1094 / tg 0.9992 | 记录（差 2.7pp 到 M1） |
| RMS#1 | spec 常量 BLOCK_SIZE（存档 `archive/rms-spec-const-attempt`） | A/B 漂亮（pp512 1.0506）但正确性崩（ppl=词表大小、0/6、退化 `!`） | **负：废弃**（glslc 折叠/驱动未裁定的双重嫌疑） |
| RMS#2 | gen 编译期 BLOCK_SIZE=128/256 变体 | pp512 1.0507 / pp2048 1.0444 / tg 1.0037；ppl Δ=0、6/6 | **采纳（`387f3638f`）** |
| M1 | official vs dev（含 RMS/L2） | pp512 1.1795 / pp2048 1.1532 / tg 1.0001 | M1 跨线 |
| E3-B/BN2 | 每 WG 双 N-tile 共享 A 条带（v1 直读 / v1c 寄存器预取） | v1：pp512 0.9753；v1c：0.9515；均 bit-exact | **负：废弃**（存档 `archive/bn2-attempt`） |
| E5A+ | 去掉 B 侧寄存器预取（省 16 VGPR，B 直读 LDS） | pp512 1.0221 / pp2048 1.0208（8 轮）；ppl Δ=0、6/6 | **采纳（`d51442c2c`）** |
| E3-A | u16 A 载入（packed16 视图，私有 pair 映射） | pp512 0.9888 / pp2048 0.9882（8 轮）；修复多槽位 bug 后 bit-exact | **负：废弃**（教训见上） |
| SSM | SSM_CONV LDS 分段（nc==4，合并加载+奇 pitch） | pp512 1.0184 / pp2048 1.0177（8 轮，累计口径）；隔离效应 +0.3~1.8%；bit-exact | **采纳（`31986a1bb`）** |
| GDN | 逐 token 载入软件流水（next-token 预取寄存器） | pp512 0.9431 / pp2048 0.9417（8 轮）；bit-exact | **负：废弃** |
| M1+ | official vs probe（终测，8 轮） | **pp512 1.1883 / pp2048 1.1764 / tg 0.9989** | 记录（M2≈1.55× 仍远） |
| CONCAT 融合 | vulkan concat 内转置拷贝（32×33 LDS）替代 conv 输入的 cont | pp512 1.0057 / pp2048 1.0068（8 轮 vs probe-ssm） | **采纳（`7e45d6509`）** |
| Plan A | 状态转置+dim1 拼接+双跨步 ssm_conv | ppl（512 块）bit-exact 但 decode 2 token 后发散（0/6）；**SSM_CONV 契约要求 src0->nb[0]==4**（CPU 断言证实） | **负：废弃**（教训见下） |
| RMS 缓存 | rms_norm 行存 f32 LDS，消除第二读 | 逐位一致（f16 试探版曾 -0.123%，已改 f32 精确复刻） | **采纳（`a5c0d0c7f`）** |
| 事故 | 两组 bench 并发（053426/053449）→ 全部作废；幻影通知诱导 | anchor 掉到 ~280，波动作废 | 教训入档（通知不可信，查进程+CSV） |

## 下一步队列（2026-10-18 17:55 更新，会话收官）
0. **【全部闭环】**：GEMM 结构线（wave32 收割后收干）；两小项（sigmoid+mul、add+rms+mul）已实现验证但因复杂度/收益比回退（见上，可复活）。当前分支 = 本机可交付最优；**建议下一会话从本文件的"恢复程序"开始，先重建/复核再决定是否开新战线**。
1. 剩余可选（低值、已评估、需新会话决策）：小行（ne0≤256）add+rms 扩展（理论 ~2.6ms，需再引入上述融合机制的变体）；GDN 二段 reduce 移出关键路径（风险族）。
2. 已关闭线（勿重开）：GLU/FWHT/CONCAT/ADD/MUL（带宽顶）、L-tile/BN 变体（驱动悬崖）、plan A、GEMM 全部候选（R1b/R4'/R7/R9/PAD/reshape——实测负）、非 coopmat 内核族、RGP。
1. 剩余可选（低值、已评估，需新会话决策）：小行（ne0≤256）add+rms 扩展（需 b128/b256 变体，理论 ~2.6ms）；GDN 二段 reduce 移出关键路径（风险族）；其余队列项见 ledger（低值）。
2. 已关闭线（勿重开）：GLU/FWHT/CONCAT/ADD/MUL（带宽顶）、L-tile/BN 变体（驱动悬崖）、plan A、GEMM 全部候选（R1b/R4'/R7/R9/PAD/reshape——实测负）、非 coopmat 内核族、RGP。

## GEMM 结构攻坚（2026-10-18 已执行完毕；结果/墙图见 `GEMM-attack.md`）
> 状态：探针 P1/P2/P3 完成（+12/+13/+10% 上界）；候选 R1a 采纳（+2.8%），R1b/R4'/R7/R9/PAD/reshape 全部实测负 → 见收尾表。以下为当初的作战计划原文（存档）。

**目标量化**：当前 6.26 TFLOPS / 峰值 16.6 ≈ 38% → 目标 ≥8.3（50%）。里程碑推算：

| 利用率 | GEMM | pass | t/s | 里程碑 |
|---|---|---|---|---|
| 38%（现状） | 585ms | ~790ms | 650 | 当前（1.20×） |
| 50%（8.3T） | ~430ms | ~630ms | ~810 | ≈M2 (1.55×) |
| 60%（10T） | ~356ms | ~556ms | ~920 | M2+ |
| 70%（11.6T） | ~307ms | ~507ms | ~1010 | ≈M4 |

**第 1 步（必须先做）：脏相位移除探针重估预算**。编译期 `#if` 变体，各自跳过单一相位（结果故意错误，仅测性能，单会话内相对比较即可，不必 8 轮）：
- 跳 A 解包 ALU（存垃圾）→ 隔离 dequant ALU 成本
- 跳 A LDS 写（存对但少写）→ 隔离 LDS 写带宽
- 跳 B 装载（读垃圾）→ 复核 B 成本
- 跳 MMA（不 coopMatMulAdd，直接存 sums）→ 隔离 MMA 发射成本
- 跳 epilogue 全局写 → 隔离输出写成本
把"62% 未归属"劈开，先打最大切片。

**候选方向**（按探针结果选择；已知悬崖已标注）：
1. **指令数压缩**：`store_a` 每 idx 两次 FLOAT_TYPEV2 写 → 合成 f16vec4 写（-8 条/线程/块）；A 地址计算复用。⚠️ 任何逐 idx 位操作都要算进 ALU 预算（E3-A 教训）。
2. **A 解包重构**：LUT 天花板已探（~2-3%）；可试 SIMD-in-register 技巧省 2-bit 展位；或把解包移出关键路径（非对齐 store 的 SMP 竞争）。
3. **流水线组织**：A 双缓冲但避免寄存器爆炸（B 侧已直读）；中段屏障替代结构（BN2 教训：屏障串行 -2.5%）。
4. **Tile 配置复攻**：仅在有新寄存器预算依据时碰 L-tile（当前 -94% 悬崖）；BK=96 等非 2 次幂坐实过吗？（未试）。
5. **B/输出**：勿动（0.7%/带宽顶）。

**护城河（每次改动检查）**：+16 VGPR ≈ -2.3%；多槽位 spec 常量陷阱（映射必须从 spec 常量推导）；算子布局契约（CPU 断言是文档）；测量纪律（8 轮、单基准、安静机器、以 CSV 为准、对官方比值同会话）。

## 恢复程序（新会话 / 压缩后）
1. 读本文件 → 2. `ledger.md`（全部实验与数字）→ 3. `E1-gemm-profile.md` → 4. 按队列执行；构建/A-B/正确性命令见"常用命令"。

## 天花板与期望（战略评估，2026-10-18 06:45 更正）
- **峰值口径更正**：780M fp16 峰值 ≈ **16.6 TFLOPS**（打包 f16 = 2× FP32 ≈ 8.3T；RDNA3 WMMA 同一速率）。早前"8.3T=fp16 峰"是把 FP32 数误用，相关结论作废。
- 实测：GEMM 6.26 TFLOPS ≈ **38%**；MMA 忙碌 26%（P4）→ 一致指向数据通路/发射瓶颈。
- **里程碑可达性（更正后）**：M2（1.55×≈800）⇔ GEMM 利用率 ≥50%；M3/M4 ⇔ 60-70%。**均在数学可达区**，但都需要结构攻坚而非微优化。
- 非 GEMM 侧：~200ms 且大头已贴带宽墙（GLU/FWHT/CONCAT/ADD/MUL 关闭）→ 深挖空间 ≤30-40ms（GDN/杂项）。
- 概率（诚实，2026-10-18 更新）：M2 40-55%（取决于 GEMM 攻坚；50% 利用率是硬仗但目标明确）/ M3-M4 15-30%（需 60-70% 利用率，且实际频率可能下修峰值）。
- 节奏参考：GEMM 攻坚按"探针→单点改动→构建(4min)→A/B(25min)→正确性(10min)"循环，每循环 ≈1h。

## 踩坑备忘
- PowerShell 5.1 对原生命令 stderr 会误报为终止错误——一律用 `Start-Process -RedirectStandardOutput/Error`。
- llama-bench CSV 的 `gpu_info` 字段内含逗号——必须 `ConvertFrom-Csv`，不可 split。
- 正确性对比要剥掉：`[ Prompt: ... ]` 计时块 + `build : <hash>` 横幅行（每构建不同）。
- 同一时间只跑一个重型任务（构建 or 基准）；基准会话要"安静机器"。
- checkout 会移走未入库文件：脚本一律用运行目录副本执行（worktree 里的是源）。
- `git rebase` 后 worktree 处于新基点；`GGML_VK_*` 开关都是环境变量，不改变默认行为（除 BK64 默认开）。
