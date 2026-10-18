# bench-ab.ps1 - interleaved A/B benchmark (reference vs candidate) with median + ratio
# Usage: bench-ab.ps1 -RefDir <dir> -CandDir <dir> [-Rounds 3] [-Quick] [-Tests "pp512,pp2048,tg128"]
param(
  [Parameter(Mandatory=$true)][string]$RefDir,
  [Parameter(Mandatory=$true)][string]$CandDir,
  [int]$Rounds = 4,
  [int]$WarmupRounds = 2,
  [switch]$Quick,
  [string]$Tests = "pp512,pp2048,tg128",
  [string]$Model = "E:\models\LLM\GGUF\Ternary-Bonsai-2-4B-PQ2_0.gguf",
  [string]$OutDir = "D:\LLM\Backend\llama.cpp-prism-vk-perf\reports\raw"
)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force $OutDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"

if ($Quick) { $benchArgs = "-p 512 -n 32 -r 2" } else { $benchArgs = "-p 512,2048 -n 128 -r 2" }
$commonArgs = "-ngl 99 -fa on -dev vulkan2 -lm mlock -ub 512 -o csv"

function Invoke-Bench([string]$dir, [string]$tag, [int]$round) {
  $exe = Join-Path $dir "llama-bench.exe"
  if (!(Test-Path $exe)) { throw "llama-bench.exe not found in $dir" }
  $stdout = Join-Path $OutDir "$stamp-$tag-r$round.csv"
  $stderr = Join-Path $OutDir "$stamp-$tag-r$round.err.log"
  $argstr = "-m `"$Model`" $commonArgs $benchArgs"
  $p = Start-Process -FilePath $exe -ArgumentList $argstr -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  if ($p.ExitCode -ne 0) { throw "llama-bench failed ($tag round $round, exit $($p.ExitCode)); see $stderr" }
  $raw = [IO.File]::ReadAllText($stdout)
  if (-not $raw -or $raw.Length -lt 10) { throw "no csv output from $tag (see $stdout / $stderr)" }
  $rows = ConvertFrom-Csv $raw
  $res = @{}
  foreach ($row in $rows) {
    $nPrompt = 0; $nGen = 0; $tps = 0.0
    [void][int]::TryParse($row.n_prompt, [ref]$nPrompt)
    [void][int]::TryParse($row.n_gen, [ref]$nGen)
    if (-not [double]::TryParse($row.avg_ts, [ref]$tps)) { continue }
    $name = ""
    if ($nPrompt -gt 0) { $name += "pp$nPrompt" }
    if ($nGen -gt 0)   { $name += "tg$nGen" }
    if ($name) { $res[$name] = $tps }
  }
  return $res
}

function Get-Median([double[]]$v) {
  $s = @($v | Sort-Object)
  $n = $s.Count
  if ($n -eq 0) { return 0.0 }
  if ($n % 2 -eq 1) { return $s[[int](($n-1)/2)] }
  return ($s[$n/2 - 1] + $s[$n/2]) / 2.0
}

Write-Host "[bench-ab] warmup (discarded, $WarmupRounds rounds per side, alternating order)..."
for ($w = 1; $w -le $WarmupRounds; $w++) {
  $order = if ($w % 2 -eq 1) { @("ref","cand") } else { @("cand","ref") }
  foreach ($side in $order) {
    $dir = if ($side -eq "ref") { $RefDir } else { $CandDir }
    Invoke-Bench $dir "$side-warmup$w" 0 | Out-Null
  }
  Write-Host "[bench-ab] warmup round $w done"
}

$acc = @{ ref = @{}; cand = @{} }
for ($r = 1; $r -le $Rounds; $r++) {
  # ABBA: alternate which side runs first each round to cancel warmup/thermal drift bias
  $order = if ($r % 2 -eq 1) { @("ref","cand") } else { @("cand","ref") }
  foreach ($side in $order) {
    $dir = if ($side -eq "ref") { $RefDir } else { $CandDir }
    Write-Host "[bench-ab] round $r / $side"
    $res = Invoke-Bench $dir $side $r
    foreach ($k in $res.Keys) {
      if (-not $acc[$side].ContainsKey($k)) { $acc[$side][$k] = @() }
      $acc[$side][$k] = @($acc[$side][$k]) + $res[$k]
    }
  }
}

$testList = $Tests -split "," | ForEach-Object { $_.Trim() }
$rows = @()
foreach ($t in $testList) {
  $rv = 0.0; $cv = 0.0
  if ($acc["ref"].ContainsKey($t))  { $rv = Get-Median ([double[]]$acc["ref"][$t]) }
  if ($acc["cand"].ContainsKey($t)) { $cv = Get-Median ([double[]]$acc["cand"][$t]) }
  $ratio = if ($rv -gt 0) { [math]::Round($cv / $rv, 4) } else { 0 }
  $rows += [pscustomobject]@{ test = $t; ref_median = [math]::Round($rv,2); cand_median = [math]::Round($cv,2); ratio = $ratio }
}

$table = ($rows | Format-Table -AutoSize | Out-String)
Write-Host $table
$anchorRow = $rows | Where-Object { $_.test -eq "pp2048" }
if ($anchorRow -and $anchorRow.ref_median -gt 0 -and $anchorRow.ref_median -lt 480) {
  Write-Warning ("anchor low: ref pp2048 median = {0} t/s - unhealthy session state, use ratio with caution" -f $anchorRow.ref_median)
}
$sum = Join-Path $OutDir "$stamp-summary.txt"
($table + "`nRefDir=$RefDir`nCandDir=$CandDir`nRounds=$Rounds Quick=$Quick") | Out-File -Encoding utf8 $sum
Write-Host "[bench-ab] summary: $sum"
