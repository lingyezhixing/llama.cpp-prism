# correctness.ps1 - perplexity compare + greedy prompt smoke (ref vs cand binaries)
# Usage: correctness.ps1 -RefDir <dir> -CandDir <dir> [-MaxPplDeltaPct 1.0]
param(
  [Parameter(Mandatory=$true)][string]$RefDir,
  [Parameter(Mandatory=$true)][string]$CandDir,
  [string]$Model = "E:\models\LLM\GGUF\Ternary-Bonsai-2-4B-PQ2_0.gguf",
  [double]$MaxPplDeltaPct = 1.0,
  [string]$DataDir,
  [string]$OutDir = "D:\LLM\Backend\llama.cpp-prism-vk-perf\reports\raw"
)
$ErrorActionPreference = "Stop"
if (-not $DataDir) { $DataDir = Join-Path $PSScriptRoot "..\data" }
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
New-Item -ItemType Directory -Force $OutDir | Out-Null
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Invoke-Tool([string]$exe, [string]$argstr, [string]$tag) {
  $stdout = Join-Path $OutDir "$stamp-$tag.out.log"
  $stderr = Join-Path $OutDir "$stamp-$tag.err.log"
  $p = Start-Process -FilePath $exe -ArgumentList $argstr -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  if ($p.ExitCode -ne 0) { throw "$([IO.Path]::GetFileName($exe)) failed ($tag, exit $($p.ExitCode)); see $stderr" }
  return @{ out = (Get-Content $stdout -Raw); err = (Get-Content $stderr -Raw) }
}

function Run-Ppl([string]$dir, [string]$tag) {
  $exe = Join-Path $dir "llama-perplexity.exe"
  if (!(Test-Path $exe)) { throw "llama-perplexity.exe not found in $dir" }
  $pplFile = Join-Path $DataDir "ppl-text.txt"
  $argstr = "-m `"$Model`" -f `"$pplFile`" -c 512 -b 512 -ngl 99 -fa on -dev vulkan2 -lm mlock"
  $r = Invoke-Tool $exe $argstr "ppl-$tag"
  $txt = $r.out + "`n" + $r.err
  $m = [regex]::Match($txt, "Final estimate:\s*PPL\s*=\s*([0-9.]+)")
  if (-not $m.Success) { throw "ppl not parsed for $tag (see reports/raw)" }
  return [double]$m.Groups[1].Value
}

function Run-Prompt([string]$dir, [string]$tag, [string]$prompt, [int]$i) {
  $exe = Join-Path $dir "llama-completion.exe"
  if (!(Test-Path $exe)) { throw "llama-completion.exe not found in $dir" }
  $pf = Join-Path $OutDir "$stamp-cli-$tag-$i.prompt.txt"
  [IO.File]::WriteAllText($pf, $prompt, $utf8NoBom)
  $argstr = "-m `"$Model`" -f `"$pf`" -n 32 --temp 0 --top-k 1 --seed 1234 -ngl 99 -fa on -dev vulkan2 -st -c 2048"
  $r = Invoke-Tool $exe $argstr "cli-$tag-$i"
  # strip the trailing timings block ("[ Prompt: ... ]" and "Exiting...") which varies run to run,
  # and normalize the banner build line which embeds a different commit hash per binary
  $t = $r.out -replace '(?s)\[\s*Prompt:.*$', ''
  $t = $t -replace '(?m)^build\s*:.*$', 'build: X'
  return ($t.TrimEnd())
}

function Get-CommonPrefix([string]$a, [string]$b) {
  $n = [Math]::Min($a.Length, $b.Length)
  for ($i = 0; $i -lt $n; $i++) { if ($a[$i] -ne $b[$i]) { return $i } }
  return $n
}

Write-Host "[correctness] perplexity ..."
$pplRef = Run-Ppl $RefDir "ref"
$pplCand = Run-Ppl $CandDir "cand"
$pplDelta = [math]::Round(($pplCand - $pplRef) / $pplRef * 100, 3)
Write-Host ("[correctness] ppl ref={0} cand={1} delta={2}%" -f $pplRef, $pplCand, $pplDelta)

$prompts = Get-Content (Join-Path $DataDir "prompts.txt") -Encoding utf8 | Where-Object { $_ -and -not $_.StartsWith("#") }
$identical = 0; $total = 0; $notes = @()
$i = 0
foreach ($p in $prompts) {
  $i++
  $total++
  $ro = Run-Prompt $RefDir "ref" $p $i
  $co = Run-Prompt $CandDir "cand" $p $i
  $cp = Get-CommonPrefix $ro $co
  $same = ($cp -eq $ro.Length -and $cp -eq $co.Length)
  if ($same) { $identical++ ; $notes += "prompt ${i}: identical" }
  else { $notes += ("prompt {0}: diverged at char {1} (ref len {2}, cand len {3})" -f $i, $cp, $ro.Length, $co.Length) }
}

Write-Host "[correctness] prompts identical: $identical / $total"
$notes | ForEach-Object { Write-Host "  $_" }

$verdict = if ([math]::Abs($pplDelta) -le $MaxPplDeltaPct) { "PPL_PASS" } else { "PPL_FAIL" }
Write-Host "[correctness] verdict: $verdict (threshold +/-$MaxPplDeltaPct%)"
$sum = Join-Path $OutDir "$stamp-correctness-summary.txt"
(@(
  "ref=$RefDir",
  "cand=$CandDir",
  "ppl_ref=$pplRef",
  "ppl_cand=$pplCand",
  "ppl_delta_pct=$pplDelta",
  "verdict=$verdict",
  "prompts_identical=$identical/$total"
) + $notes) | Out-File -Encoding utf8 $sum
Write-Host "[correctness] summary: $sum"
if ($verdict -eq "PPL_FAIL") { exit 2 }
exit 0
