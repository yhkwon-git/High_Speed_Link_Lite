$ErrorActionPreference = "Stop"
$sim = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = (Resolve-Path (Join-Path $sim "..")).Path

function Invoke-Icarus {
  $build = Join-Path $sim "build"
  New-Item -ItemType Directory -Force -Path $build | Out-Null
  $files = @()
  Get-Content (Join-Path $sim "filelist.f") | ForEach-Object {
    $line = $_.Trim()
    if ($line -eq "" -or $line.StartsWith("#")) { return }
    $files += (Join-Path $root ($line -replace "/", "\"))
  }
  $out = Join-Path $build "smoke.vvp"
  & iverilog -g2012 -o $out @files
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  & vvp $out
  exit $LASTEXITCODE
}

function Invoke-WslVerilator {
  if ($root -notmatch "^([A-Za-z]):\\(.*)$") {
    Write-Error "WSL path conversion only supports a drive-letter path. Root was $root"
  }
  $drive = $Matches[1].ToLower()
  $rest = $Matches[2] -replace "\\", "/"
  $wslRoot = "/mnt/$drive/$rest"
  wsl -e bash -lc "cd '$wslRoot' && bash sim/run_smoke.sh"
  exit $LASTEXITCODE
}

if (Get-Command iverilog -ErrorAction SilentlyContinue) {
  Invoke-Icarus
} elseif (Get-Command wsl -ErrorAction SilentlyContinue) {
  Invoke-WslVerilator
} else {
  Write-Error "No simulator found. Install Icarus Verilog, or use WSL with Verilator. Sources are listed in sim/filelist.f."
}
