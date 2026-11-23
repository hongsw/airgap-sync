<#
  airgap-sync (Windows PowerShell 5.1+ / PowerShell 7) — airgap-sync.sh 를 Git for Windows 의 bash 로 실행한다.
  로직은 airgap-sync.sh 한 곳에만 있다(두 벌로 갈라지지 않게). 인자·종료 코드는 그대로 전달한다.

  사용:  .\airgap-sync.ps1 mirror -c $HOME\.airgap-sync\airgap-sync.conf --dry-run
         .\airgap-sync.ps1 bundle-create
         .\airgap-sync.ps1 bundle-push D:\x\app-20261123.bundle --sha256 <hex> --with-packages
  bash 위치를 바꾸려면 $env:AIRGAP_BASH = 'C:\Program Files\Git\bin\bash.exe'
#>
$ErrorActionPreference = 'Continue'   # PS 5.1 은 네이티브 명령의 stderr 를 오류로 바꾼다 — Stop 금지
$script = Join-Path $PSScriptRoot 'airgap-sync.sh'

function Find-GitBash {
  if ($env:AIRGAP_BASH -and (Test-Path $env:AIRGAP_BASH)) { return $env:AIRGAP_BASH }
  $cands = @()
  $git = Get-Command git -ErrorAction SilentlyContinue
  if ($git) {
    # ...\Git\cmd\git.exe 또는 ...\Git\mingw64\bin\git.exe → ...\Git\bin\bash.exe
    $d = Split-Path $git.Source
    $cands += (Join-Path $d '..\bin\bash.exe'), (Join-Path $d '..\..\bin\bash.exe')
  }
  $cands += "$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe", "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
  foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return (Resolve-Path $c).Path } }
  # C:\Windows\System32\bash.exe 는 WSL 이다 — 쓰지 않는다
  return $null
}

$bash = Find-GitBash
if (-not $bash) {
  Write-Host '  ✗ Git for Windows 의 bash.exe 를 찾지 못했다 — Git for Windows 를 설치하거나 $env:AIRGAP_BASH 로 경로를 준다' -ForegroundColor Red
  exit 1
}
# 한글 출력이 깨지지 않게 (PS 5.1 기본 코드 페이지)
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$env:CHERE_INVOKING = '1'      # bash 가 HOME 으로 cd 하지 않게
$env:MSYS_NO_PATHCONV = $null  # 경로 변환은 스크립트가 cygpath 로 직접 한다
& $bash $script @args
exit $LASTEXITCODE
