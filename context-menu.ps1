#requires -Version 5.1

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Install', 'Uninstall')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Run', 'Claude', 'ForceDelete')]
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

$forceDeleteScript = Join-Path $PSScriptRoot 'force-delete.ps1'

# RUN and Claude open a shell you then work in, so they prefer PowerShell 7 when it is
# present and fall back to Windows PowerShell 5.1 when it is not. Resolved once here at
# install time and baked into the registry value, the same way the Force Delete command
# bakes in the worker path.
#
# (Get-Command pwsh).Source is deliberately not used. With the Store build it returns
# ...\WindowsApps\Microsoft.PowerShell_7.6.5.0_x64__8wekyb3d8bbwe\pwsh.exe, which carries
# the version number and would stop resolving at the next pwsh update. Both candidates
# below are stable across updates. A bare 'pwsh.exe' is not used either: these keys live
# in HKLM and apply to every user, so the launcher should not be resolved through a PATH
# that any single user can prepend to.
$pwshCandidates = @(
    (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')           # MSI / winget, machine-wide
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe')  # Store build, app execution alias
)
$interactiveShell = $windowsPowerShell
foreach ($candidate in $pwshCandidates) {
    if (Test-Path -LiteralPath $candidate) {
        $interactiveShell = $candidate
        break
    }
}

# Base is the registry parent the menu item lives under:
#   Directory\Background\shell  fires on right-click in the empty area inside a folder.
#   AllFilesystemObjects\shell  fires on a selected file, folder or drive. Using this one
#                               key avoids Classes\*\shell, whose literal asterisk would
#                               have to be escaped for the PowerShell registry provider.
#
# -ExecutionPolicy Bypass is required, not cosmetic. npm installs a global CLI as three
# shims, and Windows PowerShell picks the .ps1 one over the .cmd one, so `claude` resolves
# to claude.ps1. Windows PowerShell 5.1 defaults to Restricted and refuses to load it,
# which is what breaks the menu item when the 5.1 fallback above is in use. pwsh 7 defaults
# to RemoteSigned and would not need the switch, but keeping it makes both launchers behave
# the same. It only sets the process scope for the window being launched, it does not
# change machine policy.
$items = @{
    Run = @{
        Key = 'ProjectRun'
        Label = 'RUN'
        Base = 'HKLM:\Software\Classes\Directory\Background\shell'
        Shell = $interactiveShell
        Command = '"' + $interactiveShell + '" -NoLogo -NoExit -ExecutionPolicy Bypass -Command "Set-Location -LiteralPath ''%V''; yarn start"'
    }
    Claude = @{
        Key = 'ProjectClaude'
        Label = 'Claude'
        Base = 'HKLM:\Software\Classes\Directory\Background\shell'
        Shell = $interactiveShell
        Command = '"' + $interactiveShell + '" -NoLogo -NoExit -ExecutionPolicy Bypass -Command "Set-Location -LiteralPath ''%V''; claude --dangerously-skip-permissions"'
    }
    ForceDelete = @{
        Key = 'ProjectForceDelete'
        Label = 'Force Delete'
        Base = 'HKLM:\Software\Classes\AllFilesystemObjects\shell'
        # Stays on 5.1: it is a non-interactive worker, force-delete.ps1 is written and
        # verified against 5.1, and this verb is registered for every user and every
        # filesystem object, so the launcher that is always present is the safer one.
        Shell = $windowsPowerShell
        Command = '"' + $windowsPowerShell + '" -NoProfile -ExecutionPolicy Bypass -File "' + $forceDeleteScript + '" -Path "%1"'
    }
}

$itemInfo = $items[$Item]
$menuPath = Join-Path $itemInfo.Base $itemInfo.Key

if ($Action -eq 'Install' -and $Item -eq 'ForceDelete' -and -not (Test-Path -LiteralPath $forceDeleteScript)) {
    Write-Host "Missing $forceDeleteScript, cannot install Force Delete."
    Read-Host 'Press Enter to close'
    exit 1
}

if ($Action -eq 'Install') {
    New-Item -Path $menuPath -Force | Out-Null
    New-ItemProperty -Path $menuPath -Name '(default)' -Value $itemInfo.Label -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $menuPath -Name 'Icon' -Value 'powershell.exe' -PropertyType String -Force | Out-Null

    $commandPath = Join-Path $menuPath 'command'
    New-Item -Path $commandPath -Force | Out-Null
    New-ItemProperty -Path $commandPath -Name '(default)' -Value $itemInfo.Command -PropertyType String -Force | Out-Null
    Write-Host "$($itemInfo.Label) installed for all Windows users."
    # The launcher is baked into the registry value, so show which one was picked. A silent
    # fall back to 5.1 would otherwise look exactly like a successful pwsh 7 install.
    Write-Host "  shell: $($itemInfo.Shell)"
} elseif (Test-Path -LiteralPath $menuPath) {
    Remove-Item -LiteralPath $menuPath -Recurse -Force
    Write-Host "$($itemInfo.Label) removed."
} else {
    Write-Host "$($itemInfo.Label) was not installed."
}

Read-Host 'Press Enter to close'
