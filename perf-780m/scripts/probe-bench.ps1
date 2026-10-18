# probe-bench.ps1 - quick single-binary pp512 measurement for dirty GEMM probes.
# Usage: probe-bench.ps1 -BinDir <dir-with-llama-bench.exe> [-Runs 2] [-Reps 3]
param(
  [Parameter(Mandatory=$true)][string]$BinDir,
  [int]$Runs = 2,
  [int]$Reps = 3,
  [string]$Model = "E:\models\LLM\GGUF\Ternary-Bonsai-2-4B-PQ2_0.gguf"
)
$ErrorActionPreference = "Continue"
$exe = Join-Path $BinDir "llama-bench.exe"
if (!(Test-Path $exe)) { throw "llama-bench.exe not found in $BinDir" }
$results = @()
foreach ($i in 1..$Runs) {
  $errLog = Join-Path $env:TEMP "probe-bench-$i.err"
  $raw = & $exe -m $Model -ngl 99 -fa on -dev vulkan2 -lm mlock -ub 512 -o csv -p 512 -n 1 -r $Reps 2>$errLog

  $rows = $raw | ConvertFrom-Csv
  $pp = $rows | Where-Object { $_.n_prompt -eq "512" } | Select-Object -First 1
  if (-not $pp) { throw "no pp512 row from $BinDir run $i" }
  $tps = [double]$pp.avg_ts
  $results += $tps
  Write-Host ("[probe-bench] {0} run{1}: pp512 = {2:N2} t/s" -f $BinDir, $i, $tps)
}
$best = ($results | Measure-Object -Maximum).Maximum
$med = ($results | Sort-Object)[[int]($results.Count/2)]
Write-Host ("[probe-bench] {0} => best {1:N2} / median {2:N2} t/s" -f $BinDir, $best, $med)
