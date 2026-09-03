#requires -Version 5.1

# Worker for the "Force Delete" context menu item.
#
# Directory: rd /s /q. This started out as robocopy /MIR /MT against an empty folder, which
#            is the usual advice, but measured on a 24k-file tree it came out at 6.7s
#            against 2.2s for rd /s /q, and /MT:8 vs /MT:32 vs no /MT made no difference
#            at all. NTFS serialises delete metadata per volume, so extra threads buy
#            nothing and robocopy's per-file bookkeeping is pure overhead. rd is also
#            junction-safe and handled a 473-character path here, which were the other two
#            reasons to reach for robocopy.
# File:      deleted directly.
#
# Anything that survives is treated as locked. Restart Manager reports which processes
# hold it; after confirmation those are killed and the delete is retried. If it is still
# stuck, the leftovers can be queued for deletion at the next reboot.
#
# Junctions and symlinks are never walked into. rd /s /q removes the link and leaves the
# target alone, and the enumeration used by the later passes stops at reparse points, so a
# pnpm node_modules deletes its links into the global store rather than the store itself.

param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    # Set only when the script relaunches itself elevated to queue a reboot-time delete.
    [switch]$ScheduleOnly
)

$ErrorActionPreference = 'Stop'

# Restart Manager needs individual files, not a tree. Registering every leftover in a
# large directory is slow and pointless, since the same few processes hold all of them.
$LockProbeFileLimit = 100

$system32 = Join-Path $env:SystemRoot 'System32'
$cmdExe = Join-Path $system32 'cmd.exe'
$attrib = Join-Path $system32 'attrib.exe'
$windowsPowerShell = Join-Path $system32 'WindowsPowerShell\v1.0\powershell.exe'

function Read-Confirmation {
    param([string]$Prompt)
    $answer = Read-Host "$Prompt [y/N]"
    return ($answer -eq 'y' -or $answer -eq 'Y')
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-ReparsePoint {
    param([IO.FileSystemInfo]$Item)
    return [bool]($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Assert-SafeTarget {
    param([string]$FullPath)

    if ($FullPath -eq [IO.Path]::GetPathRoot($FullPath)) {
        throw "Refusing to delete a drive root: $FullPath"
    }

    $protected = @(
        $env:SystemRoot
        $env:ProgramFiles
        ${env:ProgramFiles(x86)}
        $env:ProgramData
        (Join-Path $env:SystemDrive 'Users')
        $env:USERPROFILE
    ) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }

    $normalized = $FullPath.TrimEnd('\')
    foreach ($critical in $protected) {
        # Blocks the protected path itself, and any ancestor of it.
        if ($normalized -eq $critical -or $critical.StartsWith($normalized + '\', 'OrdinalIgnoreCase')) {
            throw "Refusing to delete a system location: $FullPath"
        }
    }
}

function Invoke-NativeDelete {
    param([string]$Directory)

    # rd walks with relative traversal internally, so it never materialises an absolute path
    # over the legacy 260-character limit, and it removes a junction instead of descending
    # into it. Under ErrorActionPreference Stop a native command's stderr becomes a
    # terminating NativeCommandError, which would abort the script on exactly the
    # locked-file case the later passes exist to handle.
    $ErrorActionPreference = 'Continue'
    & $cmdExe /c rd /s /q $Directory 2>&1 | Out-Null
    # Success is decided by whether the path still exists, not by the exit code.
}

function Get-TreeEntries {
    param([string]$Directory)

    # Depth-first enumeration that stops at reparse points and yields the link itself rather
    # than anything behind it. Get-ChildItem -Recurse cannot be used for this: PowerShell 5.1
    # descends into junctions, so deleting or queueing what it returns would destroy the
    # junction's target. Descendants are added before their parent, giving deepest-first order.
    $entries = New-Object System.Collections.Generic.List[IO.FileSystemInfo]
    foreach ($child in @(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction SilentlyContinue)) {
        if ($child.PSIsContainer -and (-not (Test-ReparsePoint $child))) {
            foreach ($descendant in @(Get-TreeEntries $child.FullName)) { $entries.Add($descendant) }
        }
        $entries.Add($child)
    }
    return $entries
}

function Remove-Target {
    param(
        [string]$FullPath,
        [bool]$IsDirectory,
        [bool]$IsLink
    )

    if ($IsLink) {
        # Remove the link itself and leave whatever it points at alone.
        try {
            if ((Get-Item -LiteralPath $FullPath -Force).PSIsContainer) {
                [IO.Directory]::Delete($FullPath, $false)
            } else {
                [IO.File]::Delete($FullPath)
            }
        } catch { }
    } elseif ($IsDirectory) {
        Invoke-NativeDelete $FullPath
    } else {
        try { [IO.File]::Delete($FullPath) } catch { }
    }
}

$restartManagerSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class RestartManagerProbe
{
    [StructLayout(LayoutKind.Sequential)]
    struct RM_UNIQUE_PROCESS
    {
        public int dwProcessId;
        public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct RM_PROCESS_INFO
    {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string strServiceShortName;
        public int ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
    }

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, StringBuilder strSessionKey);

    [DllImport("rstrtmgr.dll")]
    static extern int RmEndSession(uint pSessionHandle);

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames,
        uint nApplications, RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);

    [DllImport("rstrtmgr.dll")]
    static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo,
        [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);

    // Returns "pid|appName|serviceShortName|appType" rows so the caller does not have to
    // marshal the nested structs back into PowerShell.
    public static List<string> GetLockers(string[] files)
    {
        var result = new List<string>();
        uint handle;
        var key = new StringBuilder(256);
        if (RmStartSession(out handle, 0, key) != 0) { return result; }
        try
        {
            if (RmRegisterResources(handle, (uint)files.Length, files, 0, null, 0, null) != 0) { return result; }

            uint needed = 0;
            uint count = 0;
            uint reasons = 0;
            // First call sizes the buffer, second one fills it.
            int rc = RmGetList(handle, out needed, ref count, null, ref reasons);
            if (rc == 234 && needed > 0)   // ERROR_MORE_DATA
            {
                count = needed;
                var info = new RM_PROCESS_INFO[count];
                if (RmGetList(handle, out needed, ref count, info, ref reasons) == 0)
                {
                    for (int i = 0; i < count; i++)
                    {
                        result.Add(string.Join("|", new string[] {
                            info[i].Process.dwProcessId.ToString(),
                            info[i].strAppName,
                            info[i].strServiceShortName,
                            info[i].ApplicationType.ToString()
                        }));
                    }
                }
            }
            return result;
        }
        finally { RmEndSession(handle); }
    }
}
'@

function Get-LockingProcess {
    param([string[]]$Files)

    if (-not ('RestartManagerProbe' -as [type])) {
        Add-Type -TypeDefinition $restartManagerSource -Language CSharp
    }

    $rows = [RestartManagerProbe]::GetLockers($Files)
    foreach ($row in $rows) {
        $parts = $row.Split('|')
        $appType = [int]$parts[3]
        $serviceName = $parts[2]

        # 1000 is RmCritical: a process Windows will not survive losing. Services need to be
        # stopped through the service controller, not killed, or SCM just restarts them.
        $killable = ($appType -ne 1000) -and [string]::IsNullOrEmpty($serviceName) -and ([int]$parts[0] -gt 4)

        [pscustomobject]@{
            ProcessId = [int]$parts[0]
            Name      = $parts[1]
            Service   = $serviceName
            IsCritical = ($appType -eq 1000)
            IsExplorer = ($appType -eq 4)
            Killable  = $killable
        }
    }
}

$pendingDeleteSource = @'
using System;
using System.Runtime.InteropServices;

public static class PendingDelete
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool MoveFileEx(string existing, string newName, int flags);

    // A null destination with MOVEFILE_DELAY_UNTIL_REBOOT (0x4) means "delete at next boot".
    // The entry lands in HKLM PendingFileRenameOperations and Session Manager replays it
    // before most services start, which is why a locked file can be removed this way.
    public static void Queue(string path)
    {
        if (!MoveFileEx(path, null, 0x4))
        {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
'@

function Add-RebootDelete {
    param(
        [string]$FullPath,
        [bool]$IsDirectory
    )

    if (-not ('PendingDelete' -as [type])) {
        Add-Type -TypeDefinition $pendingDeleteSource -Language CSharp
    }

    # A delayed delete only works on files and on already-empty directories, so the queue
    # has to be ordered: every file first, then directories deepest-first, then the root.
    $queue = New-Object System.Collections.Generic.List[string]
    if ($IsDirectory) {
        $entries = @(Get-TreeEntries $FullPath)
        foreach ($entry in $entries) {
            if (-not $entry.PSIsContainer) { $queue.Add($entry.FullName) }
        }
        # Already deepest-first, and junctions are queued as themselves, not walked into.
        foreach ($entry in $entries) {
            if ($entry.PSIsContainer) { $queue.Add($entry.FullName) }
        }
    }
    $queue.Add($FullPath)

    $failed = 0
    foreach ($entry in $queue) {
        try { [PendingDelete]::Queue($entry) } catch { $failed++ }
    }

    Write-Host "Queued $($queue.Count - $failed) of $($queue.Count) entries for deletion at next reboot."
    if ($failed -gt 0) {
        Write-Host "$failed entries could not be queued." -ForegroundColor Yellow
    }
}

function Clear-BlockingAttributes {
    param(
        [string]$FullPath,
        [bool]$IsDirectory
    )

    # Read-only, hidden and system attributes block deletion independently of any lock.
    # attrib writes "File not found" to stderr when a directory has no matches, and with
    # 2>&1 under ErrorActionPreference Stop that would terminate the script.
    $ErrorActionPreference = 'Continue'

    & $attrib -R -S -H $FullPath 2>&1 | Out-Null
    if ($IsDirectory) {
        & $attrib -R -S -H (Join-Path $FullPath '*') /S /D 2>&1 | Out-Null
    }
}

function Exit-Script {
    param([int]$Code)
    Write-Host ''
    Read-Host 'Press Enter to close' | Out-Null
    exit $Code
}

# ---------------------------------------------------------------- resolve and validate

try {
    $target = [IO.Path]::GetFullPath($Path)
} catch {
    Write-Host "Not a usable path: $Path" -ForegroundColor Red
    Exit-Script 1
}

if (-not (Test-Path -LiteralPath $target)) {
    Write-Host "Not found: $target" -ForegroundColor Red
    Exit-Script 1
}

try {
    Assert-SafeTarget $target
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    Exit-Script 1
}

$targetItem = Get-Item -LiteralPath $target -Force
$isLink = Test-ReparsePoint $targetItem
$isDirectory = $targetItem.PSIsContainer -and (-not $isLink)

# The elevated relaunch skips straight to queueing, the confirmation already happened in
# the unelevated instance that spawned it.
if ($ScheduleOnly) {
    Add-RebootDelete -FullPath $target -IsDirectory $isDirectory
    Exit-Script 0
}

# ------------------------------------------------------------------------- confirmation

$kind = 'file'
if ($isLink) { $kind = 'link (only the link is removed)' }
elseif ($isDirectory) { $kind = 'directory' }

Write-Host ''
Write-Host 'Force Delete' -ForegroundColor Cyan
Write-Host "  target : $target"
Write-Host "  type   : $kind"
Write-Host '  note   : permanent, the Recycle Bin is not used'
Write-Host ''

if (-not (Read-Confirmation 'Delete this permanently?')) {
    Write-Host 'Cancelled, nothing was deleted.'
    Exit-Script 0
}

# ----------------------------------------------------------------------- pass 1, fast path

$stopwatch = [Diagnostics.Stopwatch]::StartNew()
Remove-Target -FullPath $target -IsDirectory $isDirectory -IsLink $isLink

if (-not (Test-Path -LiteralPath $target)) {
    $stopwatch.Stop()
    Write-Host ''
    Write-Host "Deleted in $([math]::Round($stopwatch.Elapsed.TotalSeconds, 1))s." -ForegroundColor Green
    Exit-Script 0
}

# -------------------------------------------------------------- pass 2, attributes retry

Write-Host ''
Write-Host 'Something survived. Clearing read-only/hidden/system attributes and retrying.' -ForegroundColor Yellow
Clear-BlockingAttributes -FullPath $target -IsDirectory $isDirectory
Remove-Target -FullPath $target -IsDirectory $isDirectory -IsLink $isLink

if (-not (Test-Path -LiteralPath $target)) {
    $stopwatch.Stop()
    Write-Host ''
    Write-Host "Deleted in $([math]::Round($stopwatch.Elapsed.TotalSeconds, 1))s." -ForegroundColor Green
    Exit-Script 0
}

# --------------------------------------------------- pass 3, find and kill what holds it

if ($isDirectory) {
    $probeFiles = @(
        Get-TreeEntries $target |
            Where-Object { -not $_.PSIsContainer } |
            Select-Object -First $LockProbeFileLimit |
            ForEach-Object { $_.FullName }
    )
} else {
    $probeFiles = @($target)
}

$lockers = @()
if ($probeFiles.Count -gt 0) {
    Write-Host 'Asking Restart Manager which processes hold it.'
    $lockers = @(Get-LockingProcess -Files $probeFiles | Sort-Object ProcessId -Unique)
}

if ($lockers.Count -eq 0) {
    Write-Host ''
    Write-Host 'Still there, and no holding process was reported.' -ForegroundColor Yellow
    Write-Host 'Restart Manager does not see every kind of handle, so a lock is still likely.'
} else {
    Write-Host ''
    Write-Host 'Held by:' -ForegroundColor Yellow
    foreach ($locker in $lockers) {
        $suffix = ''
        if ($locker.IsCritical) { $suffix = '  [critical, will not be killed]' }
        elseif ($locker.Service) { $suffix = "  [service $($locker.Service), stop it instead]" }
        elseif ($locker.IsExplorer) { $suffix = '  [Explorer, your desktop will restart]' }
        Write-Host "  $($locker.ProcessId)  $($locker.Name)$suffix"
    }

    $killable = @($lockers | Where-Object { $_.Killable })
    if ($killable.Count -gt 0) {
        Write-Host ''
        if (Read-Confirmation "Kill $($killable.Count) process(es) and retry? Unsaved work in them is lost") {
            foreach ($victim in $killable) {
                try {
                    Stop-Process -Id $victim.ProcessId -Force -ErrorAction Stop
                    Write-Host "  killed $($victim.ProcessId) $($victim.Name)"
                } catch {
                    Write-Host "  could not kill $($victim.ProcessId) $($victim.Name): $($_.Exception.Message)" -ForegroundColor Red
                }
            }
            Start-Sleep -Milliseconds 500
            Remove-Target -FullPath $target -IsDirectory $isDirectory -IsLink $isLink
        }
    }
}

if (-not (Test-Path -LiteralPath $target)) {
    $stopwatch.Stop()
    Write-Host ''
    Write-Host "Deleted in $([math]::Round($stopwatch.Elapsed.TotalSeconds, 1))s." -ForegroundColor Green
    Exit-Script 0
}

# ------------------------------------------------------------ pass 4, defer to next boot

$stopwatch.Stop()
Write-Host ''
Write-Host 'Still not deletable while Windows is running.' -ForegroundColor Yellow
Write-Host "  $target"
if ($isDirectory) {
    $remaining = @(Get-TreeEntries $target).Count
    Write-Host "  $remaining entries left inside"
}
Write-Host ''
Write-Host 'It can be queued for deletion at the next reboot, which runs before the'
Write-Host 'processes that hold it start. This needs administrator rights.'
Write-Host ''

if (-not (Read-Confirmation 'Queue it for deletion at next reboot?')) {
    Write-Host 'Left in place.'
    Exit-Script 1
}

if (Test-IsAdministrator) {
    Add-RebootDelete -FullPath $target -IsDirectory $isDirectory
} else {
    # Queueing writes to HKLM, so this has to come back elevated.
    Write-Host 'Requesting administrator rights.'
    Start-Process -FilePath $windowsPowerShell -Verb RunAs -ArgumentList @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-File', "`"$PSCommandPath`""
        '-Path', "`"$target`""
        '-ScheduleOnly'
    )
}

Exit-Script 0
