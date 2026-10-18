# perf-logger.ps1 - capture ggml-vulkan per-op window profile for a given build
# Usage: perf-logger.ps1 -BinDir <dir> [-OutFile <path>]
param(
  [Parameter(Mandatory=$true)][string]$BinDir,
  [string]$OutFile = "D:\LLM\Backend\llama.cpp-prism-vk-perf\reports\raw\perf-window.txt",
  [string]$Model = "E:\models\LLM\GGUF\Ternary-Bonsai-2-4B-PQ2_0.gguf"
)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force (Split-Path $OutFile -Parent) | Out-Null
$exe = Join-Path $BinDir "llama-bench.exe"
$stdout = "$OutFile.out.tmp"
$stderr = "$OutFile.err.tmp"
$env:GGML_VK_PERF_LOGGER = "1"
try {
  $p = Start-Process -FilePath $exe -ArgumentList "-m `"$Model`" -ngl 99 -fa on -dev vulkan2 -lm mlock -ub 512 -p 512 -r 1" -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
} finally {
  Remove-Item Env:GGML_VK_PERF_LOGGER -ErrorAction SilentlyContinue
}
if ($p.ExitCode -ne 0) { throw "llama-bench failed (exit $($p.ExitCode)); see $stderr" }
# perf windows are printed to stderr; keep both streams in the output file
[IO.File]::WriteAllText($OutFile, ([IO.File]::ReadAllText($stdout) + "`n" + [IO.File]::ReadAllText($stderr)))
Remove-Item $stdout, $stderr -ErrorAction SilentlyContinue
Write-Host "[perf-logger] saved: $OutFile"
