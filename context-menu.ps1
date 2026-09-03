#requires -Version 5.1

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Install', 'Uninstall')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Run', 'Claude')]
    [string]$Item
)

$ErrorActionPreference = 'Stop'
$scriptPath = $PSCommandPath
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process -FilePath $windowsPowerShell -Verb RunAs -ArgumentList @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-File', "`"$scriptPath`""
        '-Action', $Action
        '-Item', $Item
    )
    exit 0
}

$items = @{
    Run = @{
        Key = 'ProjectRun'
        Label = 'RUN'
        Command = '"' + $windowsPowerShell + '" -NoLogo -NoExit -Command "Set-Location -LiteralPath ''%V''; yarn start"'
    }
    Claude = @{
        Key = 'ProjectClaude'
        Label = 'Claude'
        Command = '"' + $windowsPowerShell + '" -NoLogo -NoExit -Command "Set-Location -LiteralPath ''%V''; claude --dangerously-skip-permissions"'
    }
}

$basePath = 'HKLM:\Software\Classes\Directory\Background\shell'
$itemInfo = $items[$Item]
$menuPath = Join-Path $basePath $itemInfo.Key

if ($Action -eq 'Install') {
    New-Item -Path $menuPath -Force | Out-Null
    New-ItemProperty -Path $menuPath -Name '(default)' -Value $itemInfo.Label -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $menuPath -Name 'Icon' -Value 'powershell.exe' -PropertyType String -Force | Out-Null

    $commandPath = Join-Path $menuPath 'command'
    New-Item -Path $commandPath -Force | Out-Null
    New-ItemProperty -Path $commandPath -Name '(default)' -Value $itemInfo.Command -PropertyType String -Force | Out-Null
    Write-Host "$($itemInfo.Label) installed for all Windows users."
} elseif (Test-Path -LiteralPath $menuPath) {
    Remove-Item -LiteralPath $menuPath -Recurse -Force
    Write-Host "$($itemInfo.Label) removed."
} else {
    Write-Host "$($itemInfo.Label) was not installed."
}

Read-Host 'Press Enter to close'
