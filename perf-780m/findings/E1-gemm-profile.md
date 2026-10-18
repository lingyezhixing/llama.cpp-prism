# E1: PQ2_0 prefill GEMM — runtime variant, profiling & E2a config experiments

Date: 2026-10-17 · base rev: 0082ac24a (tip) · branch: perf/780m-pq2
Status: runtime variant CONFIRMED; E2a config sweep done (one positive); next: phase isolation / pipelining

## Code-level chain (confirmed)
1. Dispatch `ggml_vk_mul_mat_q_f16`: PQ2_0 prefill -> MMQ(q8_1) pipeline absent -> coopmat1 `mul_mm.comp` (`matmul_pq2_0_f32[_f16acc]`).
2. M-tile config (default tables, non-cm2): BLOCK_SIZE=128, BM=64, BN=64, BK=32, WM=64, WN=32, WMITER=2, TM=TN=TK=16, WARP=64; wg_denoms=(64,64).
3. Grid = (ceil(m/64), ceil(n/64), batch) = 1152 WGs for m=9216/n=512; A-side (weights) dequant redundancy = n/BN = 8x.
4. Dequant (mul_mm_funcs.glsl, DATA_A_PQ2_0): per idx (4 elems): 1 byte load + f16 scale + ~4 bit ops + 2x u32->f16x2 cvt + 2x(sub,mul) + 2 LDS stores; ~4 ops/elem.
5. L-tile disabled by AMD-proprietary guard (vulkan.cpp:7038: `coopmat_support && driver_id != eAmdProprietary`).

## Runtime confirmation (T8, env-gated PQ2DBG print; GGML_VK_PQ2_DEBUG=1)
- All big prefill GEMMs (m=1024..9216, n=512): `matmul_pq2_0_f32_f16acc_aligned_m`, prec=DEFAULT, coopmat=1, cm16=1, aligned=1, wg_denoms=(64,64).
- => f16acc + M-tile(64x64) + aligned path, confirmed on silicon.

## Experiment log (E2a — tile/config, env-gated single-build A/B, pp512)
| # | change | result | verdict |
|---|--------|--------|---------|
| E2a-1 | force L-tile (GGML_VK_FORCE_MUL_MAT_L) | 34.7 vs 549.6 t/s (-94%) | NEGATIVE, reverted; upstream disable justified |
| E2a-2 | M-slot BN=128 (GGML_VK_PERF_BN128) | 51.6 vs ~530 t/s (-90%) | NEGATIVE, reverted; driver codegen cliff on wider tiles |
| E2a-3 | M-slot BK=64 | 549.0 vs 529.7 t/s (+3.6%), outputs bit-identical | **ADOPTED (default-on, GGML_VK_PERF_BK64_OFF escape)**; full A/B + correctness in flight |

Observation: enlarging coopmat tiles on this driver (LLPC) collapses performance (-90%+). SWEET SPOT IS NARROW: M(64x64) + BK 32->64 only.

## Hypotheses (revised ranking)
- **H-A (E5): K-block phase serialization** — global load + dequant + barrier are serial per K-block, not overlapped with MMA. BK=64 (+3.6%, halves phase count) supports this. Next probes: (i) phase-isolation microvariants (perf-only builds: no-dequant / no-B-load / barrier variants), (ii) software pipelining (register prefetch or reduced-size double buffer; full-size double buffer needs (64+64)x(64+8)x2x2 = 36.9KB > 32KB LDS, so BM/BN must shrink to 32/64 or 64/32 for double buffering).
- H-B (E3): dequant ALU vectorization (32-bit packed qs loads, fewer cvts; ~4 ops/elem currently).
- H-D: B-side f32->f16 convert redundancy (B strip re-converted by every m-block WG; up to 144x per GEMM).
- H-C (parallel track): non-GEMM ops (~33%: CONCAT 71ms, RMS_NORM 56ms, MUL/GLU/ADD 104ms, GDN/SSM 61ms) — untouched so far.
