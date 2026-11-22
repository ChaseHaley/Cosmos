# Build rules shared by every Cosmos family repository: compiler strictness, package discovery and the
# style gate. Callers dot-source this file from their build.ps1.

# Every family package compiles under these. Callers add their collections and, where they vet only
# some packages, -vet-packages.
$CosmosStrictFlags = @(
    '-vet'
    '-vet-cast'
    '-vet-tabs'
    '-vet-using-param'
    '-strict-style'
    '-warnings-as-errors'
    '-disallow-do'
)

function Invoke-Odin {
    & odin @args
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

# The package directories directly under $Root that hold Odin files.
function Get-Packages([string] $Root) {
    if (-not (Test-Path $Root)) { return @() }
    Get-ChildItem $Root -Directory |
        Where-Object { Get-ChildItem $_.FullName -Filter *.odin -File } |
        ForEach-Object Name
}

function Get-Vcvars64([string] $Name) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { throw "MSVC C++ tools are required to build $Name (vswhere.exe not found)." }
    $visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $visualStudio) { throw "MSVC C++ tools are required to build $Name." }
    $vcvars = Join-Path $visualStudio 'VC/Auxiliary/Build/vcvars64.bat'
    if (-not (Test-Path -LiteralPath $vcvars)) { throw "MSVC x64 environment script not found: $vcvars" }
    return $vcvars
}

# Compiles one C or C++ source of the repository at $Root into $Root/build/native/<Name>.lib, unless the
# library is newer than the source.
function Build-NativeLibrary([string] $Root, [string] $Name, [string] $Source, [string] $CompilerFlags) {
    $nativeRoot = Join-Path $Root 'build/native'
    New-Item -ItemType Directory -Force $nativeRoot | Out-Null
    $library = Join-Path $nativeRoot "$Name.lib"
    $source = Join-Path $Root $Source
    if ((Test-Path $library) -and (Get-Item $library).LastWriteTimeUtc -gt (Get-Item $source).LastWriteTimeUtc) { return }
    $vcvars = Get-Vcvars64 $Name
    $object = Join-Path $nativeRoot "$Name.obj"
    $batch = Join-Path $nativeRoot "compile-$Name.cmd"
    @("@echo off", "call `"$vcvars`" >nul 2>&1", 'if errorlevel 1 exit /b 1',
      "cl /nologo /c $CompilerFlags /Fo`"$object`" `"$source`"",
      'if errorlevel 1 exit /b 1', "lib /nologo /out:`"$library`" `"$object`"") | Set-Content -LiteralPath $batch
    & cmd /d /c $batch
    if ($LASTEXITCODE -ne 0) { throw "$Name library build failed." }
}

# The native libraries cosmos:platform links from the Cosmos checkout at $Root. An app's build calls this
# for the checkout it builds against before compiling anything that imports the platform.
function Build-CosmosNative([string] $Root) {
    # C++/WinRT keeps the notification ABI and COM event ownership out of the Odin UI code.
    Build-NativeLibrary $Root 'notifications' 'native/windows_notifications.cpp' '/std:c++20 /EHsc /MT /O2 /W4 /WX'
    # The WebView2 SDK is pinned in vendor/webview2 (AIODev D-106); its loader links statically.
    $webviewInclude = Join-Path $Root 'vendor/webview2/include'
    Build-NativeLibrary $Root 'webview' 'native/windows_webview.cpp' "/std:c++20 /EHsc /MT /O2 /W4 /WX /I`"$webviewInclude`""
}

# Builds the stylecheck tool beside this file into $Output with $Flags.
function Build-StyleCheck([string] $Output, [string[]] $Flags) {
    Invoke-Odin build (Join-Path $PSScriptRoot 'stylecheck') "-out:$Output" -debug '-subsystem:console' @Flags
}

# Runs stylecheck over the hand-written Odin files under src/ of the current directory. Generated bindings
# (directories named in $GeneratedDirectories) and win32_windows.odin declarations are outside the gate.
# Relative paths and batches keep the command line under the Windows limit however long the worktree
# path or large the source tree is. Odin accepts forward slashes, which stylecheck's scoping expects.
function Invoke-StyleCheck([string] $Executable, [string[]] $GeneratedDirectories) {
    if (-not (Test-Path src)) { return }
    $generated = '\\(' + (($GeneratedDirectories | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\\'
    $source = (Resolve-Path src).Path
    $files = @(Get-ChildItem src -Recurse -Filter *.odin -File |
        Where-Object { $_.Name -ne 'win32_windows.odin' -and $_.FullName -notmatch $generated } |
        ForEach-Object { 'src/' + $_.FullName.Substring($source.Length + 1).Replace('\', '/') })
    $limit = 16000
    $run = { & $Executable @args; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE } }
    $batch = @()
    $length = 0
    foreach ($file in $files) {
        if ($batch.Count -gt 0 -and $length + $file.Length + 1 -gt $limit) {
            & $run @batch
            $batch = @()
            $length = 0
        }
        $batch += $file
        $length += $file.Length + 1
    }
    if ($batch.Count -gt 0) { & $run @batch }
}
