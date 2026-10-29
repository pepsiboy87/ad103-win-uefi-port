param(
    [string]$Root = (Get-Location).Path,
    [switch]$Clean
)
# Build the AD103 Windows-UEFI unlock application with MSVC 2022.
# No Zig required. Expects the upstream source tree at <Root>\source\
# and writes <Root>\build\BOOTX64.EFI.

$ErrorActionPreference = 'Stop'
$src = Join-Path $Root 'source'
$out = Join-Path $Root 'build'

if (-not (Test-Path -LiteralPath (Join-Path $src 'unlock\app.c'))) {
    throw "source tree not found under $src — clone the upstream repository first"
}
New-Item -ItemType Directory -Path $out -Force | Out-Null
if ($Clean) { Get-ChildItem $out -File | Remove-Item -Force -ErrorAction SilentlyContinue }

# --- locate MSVC -------------------------------------------------------------
$vswhere = Join-Path ([Environment]::GetEnvironmentVariable('ProgramFiles(x86)')) 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw 'vswhere.exe not found (Visual Studio 2022 required)' }
$install = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $install) { throw 'MSVC x64 toolchain not found' }
$vcvars = Join-Path $install 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path -LiteralPath $vcvars)) { throw 'vcvars64.bat not found' }

# --- translation units -------------------------------------------------------
$files = @(
    'unlock\app.c', 'unlock\app_io.c', 'unlock\ownership.c', 'unlock\format.c',
    'unlock\runtime.c', 'unlock\sha256.c', 'unlock\checks.c', 'unlock\port.c',
    'unlock\compat.c', 'unlock\vendor\unlock_610.c', 'unlock\vendor\prep_610.c',
    'unlock\vendor\layout_610.c', 'unlock\vendor\vbios_610.c', 'unlock\vendor\gfw_eval.c'
)

$incFlags = '/I"' + (Join-Path $src 'unlock\compat') + '" ' +
            '/I"' + (Join-Path $src 'deps\edk2\MdePkg\Include') + '" ' +
            '/I"' + (Join-Path $src 'deps\edk2\MdePkg\Include\X64') + '"'

# GU_TARGET_PCI_ID is the vendor:device pair, little-endian dword: 10de:2704 -> 0x270410de
$cflags = '/nologo /c /std:c11 /O1 /W1 /GS- /GR- /Zl ' +
          '/D__KERNEL__ /DGU_UEFI_PORT /DGU_TARGET_PCI_ID=0x270410deU ' +
          '/D_CRT_SECURE_NO_WARNINGS ' + $incFlags

# --- generate a batch file so cl.exe runs inside the vcvars environment ------
$bat = Join-Path $Root 'build_step.bat'
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('@echo off')
$lines.Add('call "' + $vcvars + '" >nul')
$lines.Add('if errorlevel 1 exit /b 2')

$objects = @()
foreach ($f in $files) {
    $full = Join-Path $src $f
    if (-not (Test-Path -LiteralPath $full)) { throw "missing source: $f" }
    $obj = Join-Path $out ((Split-Path $f -Leaf) -replace '\.c$', '.obj')
    $objects += $obj
    $lines.Add('echo === ' + $f + ' ===')
    $lines.Add('cl.exe ' + $cflags + ' /Fo"' + $obj + '" "' + $full + '"')
    $lines.Add('if errorlevel 1 exit /b 1')
}

$efi = Join-Path $out 'BOOTX64.EFI'
$objList = ($objects | ForEach-Object { '"' + $_ + '"' }) -join ' '
$lines.Add('echo === LINK ===')
$lines.Add('link.exe /nologo /subsystem:efi_application /entry:EfiMain /nodefaultlib ' +
           '/machine:x64 /debug:none /out:"' + $efi + '" ' + $objList)
$lines.Add('if errorlevel 1 exit /b 3')
$lines.Add('exit /b 0')

Set-Content -LiteralPath $bat -Value $lines -Encoding ascii

$output = cmd.exe /c $bat 2>&1
$code = $LASTEXITCODE
$output | ForEach-Object { if ($_ -match 'error|warning C|===|LINK') { Write-Host $_ } }
if ($code -ne 0) { Write-Host ("BUILD_FAILED exit=" + $code); exit $code }

$bytes = [IO.File]::ReadAllBytes($efi)
$hash = (Get-FileHash -LiteralPath $efi -Algorithm SHA256).Hash.ToLower()
Write-Host ('BUILD_OK size=' + $bytes.Length + ' sha256=' + $hash)
