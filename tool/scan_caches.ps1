param(
    [string]$OutputPath = (Join-Path $env:TEMP 'cleanup_scan.csv')
)

$ErrorActionPreference = 'SilentlyContinue'
$out = $OutputPath
$userProfile = $env:USERPROFILE
$localAppData = $env:LOCALAPPDATA
$roamingAppData = $env:APPDATA
$systemRoot = $env:SystemRoot
$systemDrive = $env:SystemDrive
"bytes|path" | Set-Content -LiteralPath $out -Encoding UTF8

function Get-Sz([string]$p) {
    $o = robocopy $p NULL /L /S /NJH /NFL /NDL /BYTES /XJ /R:0 /W:0 /NP
    $rows = @($o | Where-Object { $_ -match '^\s*[^\s:]+:\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s*$' })
    if ($rows.Count -ge 3) {
        $nums = @((($rows[2] -replace '[^0-9]', ' ') -split '\s+') | Where-Object { $_ -ne '' })
        if ($nums.Count -gt 0) { return [int64]$nums[0] }
    }
    return [int64](-1)
}

$paths = @(
    (Join-Path $localAppData 'Temp'),
    (Join-Path $systemRoot 'Temp'),
    (Join-Path $localAppData 'Pub\Cache'),
    (Join-Path $localAppData 'Pub\Cache\hosted'),
    (Join-Path $userProfile '.gradle\caches'),
    (Join-Path $userProfile '.gradle\wrapper\dists'),
    (Join-Path $userProfile '.android\avd'),
    (Join-Path $userProfile '.android'),
    (Join-Path $systemRoot 'SoftwareDistribution\Download'),
    (Join-Path $systemRoot 'Installer'),
    (Join-Path $systemRoot 'WinSxS'),
    (Join-Path $userProfile 'Downloads'),
    (Join-Path $userProfile 'Documents'),
    (Join-Path $roamingAppData 'Code'),
    (Join-Path $localAppData 'Code'),
    (Join-Path $userProfile '.vscode\extensions'),
    (Join-Path $localAppData 'Google\Chrome\User Data'),
    (Join-Path $localAppData 'Microsoft\Edge\User Data'),
    (Join-Path $localAppData 'Packages'),
    (Join-Path $localAppData 'Microsoft\Windows\Explorer'),
    (Join-Path $localAppData 'Microsoft\Windows\INetCache'),
    (Join-Path $localAppData 'CrashDumps'),
    (Join-Path $systemDrive '$Recycle.Bin'),
    $env:ProgramFiles,
    [Environment]::GetFolderPath('ProgramFilesX86'),
    (Join-Path $localAppData 'Programs'),
    (Join-Path $userProfile 'flutter'),
    (Join-Path $localAppData 'Android\Sdk')
)

foreach ($p in $paths) {
    if (-not (Test-Path -LiteralPath $p)) {
        "-2|$p [NOT FOUND]" | Add-Content -LiteralPath $out -Encoding UTF8
        continue
    }
    $sz = Get-Sz $p
    "$sz|$p" | Add-Content -LiteralPath $out -Encoding UTF8
}

"END" | Add-Content -LiteralPath $out -Encoding UTF8
