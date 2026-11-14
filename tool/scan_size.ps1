param(
    [string]$RootPath = "$($env:SystemDrive)\",
    [string]$OutputPath = (Join-Path $env:TEMP 'cleanup_scan_top.txt')
)

$ErrorActionPreference = 'SilentlyContinue'

function Get-DirSize {
    param([string]$Path)
    $sum = [int64]0
    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        try {
            foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($d)) {
                try {
                    $attributes = [System.IO.File]::GetAttributes($entry)
                    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                    if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                        $stack.Push($entry)
                    } else {
                        $sum += (New-Object System.IO.FileInfo $entry).Length
                    }
                } catch { }
            }
        } catch {
            continue
        }
    }
    return $sum
}

$targets = @(Get-ChildItem -LiteralPath $RootPath -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })

$rows = @()
foreach ($t in $targets) {
    $s = Get-DirSize $t
    $rows += [pscustomobject]@{ Path = $t; GB = [math]::Round($s / 1GB, 2) }
}
$rows | Sort-Object GB -Descending | Format-Table -AutoSize | Out-String -Width 200 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
