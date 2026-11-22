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
