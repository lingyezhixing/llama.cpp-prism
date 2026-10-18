@echo off
rem build-vk.bat <build-name> <mirror|lean|debug>
rem mirror: CI-parity flags (minus BoringSSL). lean: fast iteration flags. debug: lean + GGML_VULKAN_DEBUG=ON.
rem Output: D:\LLM\Backend\builds\<build-name>
setlocal
set WT=C:\Users\31940\.local\share\opencode\worktree\05b616\780m-pq2
set VULKAN_SDK=E:\Program files\DevTools\VulkanSDK\1.4.313.2
if "%~1"=="" ( echo usage: build-vk.bat ^<build-name^> ^<mirror^|lean^|debug^> & exit /b 2 )
set OUT=D:\LLM\Backend\builds\%~1
set MODE=%~2
if "%MODE%"=="" set MODE=mirror
call "E:\Program files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 ( echo VCVARS_FAILED & exit /b 1 )
set PATH=%VULKAN_SDK%\Bin;%PATH%
if /i "%MODE%"=="mirror" (
  set CMAKEARGS=-DGGML_VULKAN=ON -DGGML_NATIVE=OFF -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON -DGGML_OPENMP=OFF -DLLAMA_BUILD_BORINGSSL=OFF -DLLAMA_BUILD_EXAMPLES=ON -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_SERVER=ON -DGGML_RPC=ON
  set GEN=-G "Ninja Multi-Config"
  set CFG=--config Release
) else if /i "%MODE%"=="debug" (
  set CMAKEARGS=-DGGML_VULKAN=ON -DGGML_VULKAN_DEBUG=ON -DGGML_NATIVE=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DGGML_RPC=OFF -DCMAKE_BUILD_TYPE=Release
  set GEN=-G Ninja
  set CFG=
) else (
  set CMAKEARGS=-DGGML_VULKAN=ON -DGGML_NATIVE=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DGGML_RPC=OFF -DCMAKE_BUILD_TYPE=Release
  set GEN=-G Ninja
  set CFG=
)
echo [build-vk] wt=%WT%
echo [build-vk] out=%OUT% mode=%MODE%
cmake -S %WT% -B %OUT% %GEN% %CMAKEARGS%
if errorlevel 1 ( echo CONFIGURE_FAILED & exit /b 1 )
if /i "%MODE%"=="mirror" (
  cmake --build %OUT% %CFG% -j 8
) else (
  cmake --build %OUT% %CFG% -j 8 --target llama-bench llama-completion llama-perplexity
)
if errorlevel 1 ( echo BUILD_FAILED & exit /b 1 )
echo BUILD_OK
exit /b 0
