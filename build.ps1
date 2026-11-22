[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('check', 'test')]
    [string] $Task = 'check',

    [Parameter(Position = 1)]
    [string] $Package,

    # Exact Odin test names, comma-separated; use with one package for a focused rerun.
    [ValidatePattern('^[A-Za-z0-9_.,]*$')]
    [string] $TestNames,

    [ValidateRange(1, 900)]
    [int] $TestTimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
if ($TestNames -and ($Task -ne 'test' -or -not $Package)) { throw 'TestNames requires test and a package.' }
. "$PSScriptRoot/tools/build-common.ps1"

$sourcePackages = @(Get-Packages 'src')
$testPackages = @(Get-Packages 'tests')
$toolPackages = @(Get-Packages 'tools')
$vetPackages = $sourcePackages + $toolPackages + ($testPackages | ForEach-Object { "${_}_test" })

# Only the cosmos collection exists here, so a package that imports an app cannot compile.
$flags = @('-collection:cosmos=src') + $CosmosStrictFlags
if ($vetPackages) { $flags += "-vet-packages:$($vetPackages -join ',')" }

New-Item -ItemType Directory -Force build | Out-Null

switch ($Task) {
    'check' {
        Build-StyleCheck 'build/stylecheck.exe' $flags
        Invoke-StyleCheck 'build/stylecheck.exe' @('dwrite', 'shaders')
        foreach ($name in $sourcePackages) {
            Invoke-Odin check "src/$name" -no-entry-point @flags
        }
        foreach ($name in $toolPackages) {
            Invoke-Odin check "tools/$name" @flags
        }
    }
    'test' {
        . "$PSScriptRoot/tools/test-budget.ps1"
        $targets = if ($Package) { @($Package) } else { $testPackages }
        if ($targets.Count -eq 0) { throw 'No test packages found under tests/.' }
        foreach ($name in $targets) {
            if ($name -notin $testPackages) { throw "No test package named $name." }
        }
        $budget = Enter-TestBudget
        try {
            # Run every package so one failure does not hide the state of the rest.
            $failed = @()
            foreach ($name in $targets) {
                $required = if ($TestNames) { $TestNames.Split(',') } else { @() }
                $run = Invoke-OdinTest "tests/$name" $name $flags $TestNames $required $TestTimeoutSeconds
                if ($run.Code -ne 0) { $failed += $name }
            }
            if ($failed) {
                Write-Output "Failed test packages: $($failed -join ', ')"
                exit 1
            }
        } finally {
            Exit-TestBudget $budget
        }
    }
}
