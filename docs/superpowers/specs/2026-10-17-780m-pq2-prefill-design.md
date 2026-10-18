# 780M · Ternary-Bonsai-2-4B-PQ2_0 预填充性能优化设计

- 日期: 2026-10-17
- 状态: 待批准（批准后进入计划与实施）
- 目标一句话: 把 Bonsai PQ2_0 在 Radeon 780M（Vulkan）上的 prefill 从 ~520 t/s 压到 **1000 t/s 上限目标**，decode 不回归，输出质量不退化。

## 1. 意图与目标数字

物理账（每个 512-token ubatch ≈ 995ms 实测分解）:

| 部分 | 现状 | 1000 t/s 需要 |
|---|---|---|
| PQ2_0 GEMM（coopmat1 路径） | 611ms（~5 TFLOPS） | ~255ms（~12 TFLOPS） |
| 其余（f32 GEMM + 约 20 类非 GEMM 算子） | 384ms | ~257ms（-33%） |
| 合计 | 995ms（≈515 t/s） | 512ms（=1000 t/s） |

- 硬件上限（自建微基准实测）: f16 WMMA 16.15 TOPS（= 官方 16.6 的 97%）；int8 同速；int4 经 Vulkan 不可用；读带宽 68 GB/s。
- 敏感性: GEMM 单独到 12T 只能到 ~800 t/s；10T + 非 GEMM -33% 约 910；**双达标（12T + -33%）恰为 1000**。10-12T 是 coopmat1 带内解包 kernel 的现实波段。
- 里程碑（顺序承诺，非日期承诺）: M1 ≥600 → M2 ≥800 → M3 ≥950 → M4 1000。每档需正确性全套通过。

## 2. 边界与验收

### 非目标
- 不改模型文件/量化；不引入 CPU 分担；不放宽运行时参数（保持 `-ngl 99 -fa on -lm mlock -dev vulkan2 -ub 512`）。
- 不动 CUDA/CPU 后端；不追求其他设备通用性（允许 780M 特化）。
- 不以牺牲输出质量为代价换速度。

### 反目标（出现即回退该实验）
- 输出肉眼可见退化（困惑度恶化超阈、样本胡言乱语）。
- decode tg 回归（低于同会话官方中位数 5% 即调查；绝对值仅记录）。
- 崩溃/挂起/数值性错误进入交付版本。

### 性能验收（锚定协议）
- 主指标 pp2048（llama-bench）；副指标 pp512、tg128。**判定一律相对官方二进制、同会话、交错 A/B（≥3 对，取中位数）**。
- 跨会话漂移 ±30-45%（实测），故不用跨会话绝对值判定：
  - 里程碑倍数（对官方二进制同会话中位数）: M1 ≥1.15×（≈600 t/s）、M2 ≥1.55×（≈800）、M3 ≥1.83×（≈950）、M4 ≥1.90×（≈1000）。
  - 里程碑判定要求该会话锚值健康（pp2048 官方 ≥ ~500 t/s）；锚偏低的会话（冷机等）只记方向、不作判定。
  - 绝对 t/s 照常记录并汇报（用户关心真实墙钟）。
  - decode 守护: 候选 tg ≥ 官方同会话中位数 × 0.95；绝对值仅记录。
- 单实验判定: 同会话内 >2% 才计为真实提升。

### 正确性验收（用户口径：允许规约顺序导致的微小数值漂移，实现必须正确）
- `llama-perplexity` 对照（固定中英混合文本）：Δ ≤ 1%，超阈回退。
- 固定 prompt greedy 冒烟（≥4 条，含 chores 实际提示词模板）。
- 每项实验先正确性、后性能；结论记入实验台账。

## 3. 关键事实（已核实到代码行）

- 源码: `D:\LLM\Backend\src\llama.cpp-prism`（fork `lingyezhixing/llama.cpp-prism`；upstream = PrismML-Eng/llama.cpp）。
- 基线提交: `e3de715`（rev 计数 10777，与官方二进制 `prism-b10777` 同源）。`upstream/prism` tip 现有 5 个新提交（含 #366 Vulkan FWHT 修复、#363 Bonsai2 `-sm tensor` 支持），中后段评估并入。
- PQ2_0 在 Vulkan 的实现结构:
  - prefill 主路径 = **coopmat1**：`mul_mm.comp` 编译出 `matmul_pq2_0_*`（生成器 490 行确认来源）；16×16×16 WMMA；
  - 无 coopmat2、无 MMQ 变体（生成器 596-597、627 行显式排除）；
  - A 侧解包: `mul_mm_funcs.glsl:196` 起——每字节 4 个 2-bit 码，值 = `d*(code-1)`，fp16 scale 每 128 元素一组；块结构见 `types.glsl:235`；
  - decode/小批量走 `mul_mat_vecq`（如 `mul_mat_vec_pq2_0_q8_1_f32`）。
  - 已实证：关闭 coopmat 整体 -52% ⇒ 主路径确为 coopmat1，无旁路捷径。
- 工具链齐备: VS2022 + CMake 4.4.3 + Ninja 1.13.2 + Vulkan SDK 1.4.313.2（与发布 CI 同版本）。
- 发布 CI 构建参数（parity 镜像目标）:
  `-DGGML_VULKAN=ON -DGGML_NATIVE=OFF -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON -DGGML_OPENMP=OFF -DLLAMA_BUILD_BORINGSSL=ON -DLLAMA_BUILD_EXAMPLES=ON -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_SERVER=ON -DGGML_RPC=ON`（BoringSSL 若构建受阻可关闭并记录，不影响 Vulkan 性能）。
- 驱动怪癖（实测）: 未申报的 coopmat 形状可能"能跑但结果错误"；所有改动必须过正确性。
- 非 GEMM 现状清单（ubatch 内）: CONCAT 71.4 / RMS_NORM 56.1 / MUL 45.5 / GLU 40.8 / GDN 36.4 / SSM_CONV 24.5 / ADD 17.5 / L2_NORM 10.3 / CONT 10.2 / FA 9.2 / ROPE 3.2（ms）。
- 原"f32 GEMM 48.5ms"经评审修正为 **FWHT/Hadamard 旋转路径**（形状 m=512×n×k=512 = block_size 的 rot；另含 2 个小型 ssm f32 matmul）。本模型为 Hadamard-folded（GGUF: block_size=512，sign_widths=2560/4096/9216，约 200 个 folded 权重），MUL 类中有大量 sign 乘法——按"融合/专用 kernel"视角优化（见 Phase 2.5），并优先评估复用上游已有分支。
- 官方基线二进制: `D:\LLM\Backend\llama.cpp-prism-vulkan\`（prism-b10777 Release，含 llama-bench/llama-server/llama-perplexity 与 ggml-cpu-*.dll 全套）。

## 4. 工作安排

### Phase 0 搭建与校准（先决条件）
1. 独立 worktree：`C:\Users\31940\.local\share\opencode\worktree\05b616\780m-pq2`（harness 管理），分支 `perf/780m-pq2`；主克隆保持 master 不动。
2. 镜像 CI 参数构建 Vulkan Release（Ninja Multi-Config）；产物汇集到运行目录 `D:\LLM\Backend\llama.cpp-prism-vk-perf\`。
3. **parity 校准**：e3de715 自建版 vs 官方二进制交错 A/B；|Δ| ≤ 2% 通过，否则查因（工具链差异逐项排）。
4. **上游新提交评估与采纳**：构建 `upstream/prism` tip（含 #366 Vulkan FWHT 融合修复、#363 `-sm tensor` 支持等 5 个提交）；与 e3de715 自建版交错 A/B + 正确性全套。tip 不劣且正确 ⇒ **基线切换到 tip**（分支基点改为 tip），否则留 e3de715 并记录原因。
5. 正确性数据落盘（运行目录 `correctness-data\`）：固定中英混合 ppl 文本（~20-50KB）、≥4 条 greedy prompt（含 chores 实际提示词模板，参考 `D:\LLM\Backend\Chat-Template\llama.cpp\Qwen3.5-chat_template.jinja`）。
6. 三件套脚本：`bench-ab.ps1`（交错 A/B + 中位数 + 倍数计算）、`correctness.ps1`（ppl + prompt 冒烟）、`perf-logger.ps1`（`GGML_VK_PERF_LOGGER=1` op 级窗口）。
7. 基准台账落盘（`reports\`，字段: 日期/配置/变更/pp512/pp2048/tg/正确性/结论）。

退出条件：parity 通过 + 基线定版（e3de715 或 tip）+ 台账就绪。

### Phase 1 PQ2_0 GEMM（611ms → 目标 ~255ms）
1. **E1 画像**：op 级基线；确认运行时实际选用的 variant（acc 类型、tile/wg denom、subgroup 尺寸）；建立"每 GEMM 耗时-TFLOPS 表"。
2. **E2 配置扫描**：为 12CU/32KB LDS 扫 tile/warptile 配置（零语义变化）。
3. **E3 解包向量化**：`load_a` 的 PQ2_0 解包指令数压缩（位运算批量展开、成对 f16 转换、寄存器压力），目标 +15-25%。
4. **E4 复用重构**：降低解包在 N 方向的重复率（每份解包产出更多 MMA）——预期最大杠杆（7→10T）。
5. **E5 流水线/LDS**：双缓冲、bank 冲突、fragment 预取与调度（10→12T）。
6. **E6 备选**：若 coopmat1 饱和 <10T：评估自研 `mul_mm` PQ2_0 变体、或 int8 点积替代路线；再不行接受并转战 Phase 2。

每步独立小步提交 + A/B + 正确性冒烟。shader 改动经 `vulkan-shaders-gen` 重新生成，构建时间可控。

### Phase 2 非 GEMM 算子（384ms → 目标 ~257ms）
1. **CONCAT 71ms**（24 次 × 2.97ms，明显病态）：定位调用点，修实现（向量化/去冗余拷贝/并入下游读取）。
2. **RMS_NORM 56ms**：WG 配置与形状匹配、向量化、scale 乘法融合。
3. **MUL 45.5 + GLU 40.8 + ADD 17.5**：逐元素类；向量化、配置、可融合项融合。
4. **GDN 36.4 + SSM_CONV 24.5**：fork 新代码，按新代码标准逐 op 审查。
5. **FWHT/Hadamard 旋转 ~48.5ms**（原误标 f32 GEMM）：先评估复用上游分支（`perf/fwht-metal-vulkan-prism`、`up/fwht-vulkan`、`vk-fwht-wide`、`perf/fwht-large-blocks` 等；逐个 diff 评估后择优 A/B + 正确性）；不足再自研（按带宽/占用率/寄存器块尺寸视角）。
6. 小项 L2_NORM/CONT/FA/ROPE ~33ms 顺手处理。
7. 复算非 GEMM 组合 ≤257ms 且 tg 无回归。

### Phase 3 整合与交付
1. 最终验收：性能 + 正确性全套交错 A/B。
2. 评估并入 upstream/prism 5 个新提交；并入后复测。
3. 交付：优化分支（本地提交序列）、运行目录最终二进制、结果报告（含每实验结论与数据）。
4. 可选：chores 切换脚本 + 保温建议（启动后哑请求预热，规避冷机 -30-45%）。
5. 推送 GitHub / PR / 发布：仅获胜者明确批准后执行。

## 5. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| GEMM 卡在 9-10T | 1000 需非 GEMM -50% 以上 | E6 备选路线；或如实停在 900± 并报告饱和点 |
| 数值漂移超限 | 输出质量 | ppl 阈值卡口；每实验先正确性；即回退 |
| 状态漂移吞掉小改进 | 误判 | 严格交错协议 + 2% 门槛 + 会话内重复 |
| Windows 构建/着色器生成摩擦 | 进度 | 工具链已核实；镜像 CI 参数；必要时裁剪 BoringSSL |
| 驱动怪癖 | 正确性 | 只用申报形状；正确性先行 |
| GDN 新代码理解成本 | 进度 | 已定位文件；逐 op 拆解 |
| 上游 tip 采纳（模型加载/融合路径变化） | 正确性/基线漂移 | 采纳前全量正确性 + 交错 A/B；保留 e3de715 回退 |

## 6. 工作产物（路径）

- worktree: `C:\Users\31940\.local\share\opencode\worktree\05b616\780m-pq2`（分支 `perf/780m-pq2`，harness 管理）
- 构建目录: `D:\LLM\Backend\builds\<name>`（执行期定案：C 盘余量受限，构建输出放 D 盘）
- 运行目录: `D:\LLM\Backend\llama.cpp-prism-vk-perf\`（自建二进制 + 脚本）
- 台账/报告: 运行目录 `reports\`
- 本设计文档: `docs\superpowers\specs\2026-10-17-780m-pq2-prefill-design.md`
- 基准命令模板:
  `llama-bench.exe -m E:\models\LLM\GGUF\Ternary-Bonsai-2-4B-PQ2_0.gguf -ngl 99 -fa on -dev vulkan2 -lm mlock -ub 512 -p 512,2048 -n 128 -r 2`
- 备用工具: vkpeakm（Vulkan 微基准，现存 temp 目录，可拷入项目目录）

## 7. 已拍板的决定（可推翻）

1. 分支基点：先 e3de715 完成 parity；随后评估采纳 upstream/prism tip（通过则基点切 tip，含 #366 等"白拿"收益）。官方二进制始终为对外锚点。
2. 独立 worktree；主克隆保持 master。
3. 测量协议 = 交错 A/B + 热身 + 中位数 + 2% 门槛。
4. 工作顺序 = GEMM 先行（61.5%），非 GEMM 随后（33%）。
5. 每个实验一个本地小提交；**不发生任何推送**（推送/发布需逐次批准）。
6. 1000 = 上限目标；到不了就以数据说明饱和点，不做无证据承诺。
7. 数值漂移预算 = 困惑度 Δ≤1% + 输出肉眼正常。
8. 达成里程碑或遇方向性抉择时汇报（数字 + 结论 + 下一步）。
9. 允许改跨后端共享的图/模型代码（`llama-graph.cpp`、`src/models/` 等），前提：其它后端不被破坏（保守改动）、同效时优先 Vulkan 局部方案（shader/backend）——CONCAT/融合类优化的授权基础。
