# ==============================================================================
# SCRIPT: TRaSH Extractor (The "Dumb" Ingest Daemon)
# VERSION: 2.1.1 (Interactive Configuration & Spinner Restored)
# PURPOSE: Prompts user for drive parameters at runtime. Watches the optical 
#          drive with a heartbeat spinner, parses MakeMKV's raw robot output, 
#          draws a live progress bar, handles errors, ejects, and loops.
# ==============================================================================

$backupRoot = "D:\media\backups"
$makemkvExe = "C:\Program Files (x86)\MakeMKV\makemkvcon64.exe"

# --- INTERACTIVE STARTUP SEQUENCE ---
Clear-Host
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host " TRaSH-Extractor Node Configuration" -ForegroundColor Yellow
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""

$rawDrive = Read-Host " Enter the Windows Drive Letter for this Node (e.g., E, F)"
$TargetDrive = $rawDrive.Replace(":", "").Trim()

Write-Host "`n [MakeMKV Hardware Indexing]" -ForegroundColor DarkGray
Write-Host " MakeMKV uses 0-based indexing for optical drives." -ForegroundColor DarkGray
Write-Host " -> First optical drive  = 0" -ForegroundColor DarkGray
Write-Host " -> Second optical drive = 1" -ForegroundColor DarkGray

$discNumber = Read-Host " Enter the MakeMKV Disc ID number for this Node"
$DiscId = "disc:" + $discNumber.Trim()

Clear-Host
# ------------------------------------

$spinner = @('|', '/', '-', '\')
$counter = 0

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host " TRaSH-Extractor Daemon Online" -ForegroundColor Cyan
Write-Host " Node Assigned to Optical Drive: $TargetDrive`:" -ForegroundColor Yellow
Write-Host " Locked onto Hardware ID:        $DiscId" -ForegroundColor Yellow
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""

# Initialization spinner just to confirm the daemon is alive before checking the drive
for ($i = 0; $i -lt 8; $i++) {
    $frame = $spinner[$i % 4]
    Write-Host "`r  > Initializing daemon heartbeat... $frame " -NoNewline -ForegroundColor DarkGray
    Start-Sleep -Milliseconds 150
}
Write-Host "`r                                                                       `r" -NoNewline

$fso = New-Object -ComObject Scripting.FileSystemObject

while ($true) {
    $drive = $fso.GetDrive("$TargetDrive`:")
    
    if ($drive.IsReady) {
        # Erase the idle spinner cleanly
        Write-Host "`r                                                                       `r" -NoNewline
        
        $volumeName = $drive.VolumeName
        if ([string]::IsNullOrWhiteSpace($volumeName)) { $volumeName = "UNKNOWN_DISC_$(Get-Date -Format 'yyyyMMdd_HHmmss')" }
        
        $backupPath = Join-Path $backupRoot $volumeName
        
        if (Test-Path $backupPath) {
            Write-Host "  > [SKIP] $volumeName is already backed up." -ForegroundColor DarkGray
            Start-Sleep -Seconds 30
            continue
        }

        Write-Host "`n=================================================" -ForegroundColor Magenta
        Write-Host "DISC DETECTED: $volumeName" -ForegroundColor Yellow
        Write-Host "  > Ripping Decrypted Backup to NVMe..." -ForegroundColor Cyan
        
        New-Item -ItemType Directory -Path $backupPath | Out-Null
        
        # --- THE ROBOT MODE PIPELINE ---
        & $makemkvExe backup --decrypt --cache=1 --progress=-same -r $DiscId $backupPath 2>&1 | ForEach-Object {
            $line = $_.ToString()
            
            # PARSER A: Look for Progress Values (PRGV:current,total,max)
            if ($line -match '^PRGV:(\d+),(\d+),(\d+)') {
                $current = [double]$matches[1]
                $total   = [double]$matches[2]
                $max     = [double]$matches[3]
                
                if ($max -gt 0) {
                    $percent = [math]::Round(($total / $max) * 100, 1)
                    
                    # Force the percentage to always take up exactly 5 characters to stop UI jitter
                    $formattedPercent = "{0,5:N1}" -f $percent
                    
                    # Draw the actual bar
                    $barLength = 40
                    $filled = [math]::Floor(($percent / 100) * $barLength)
                    $empty = $barLength - $filled
                    $bar = "[" + ("#" * $filled) + ("-" * $empty) + "]"
                    
                    # \r snaps to beginning of line. The blank spaces at the end erase ghost characters.
                    Write-Host "`r  > Progress: $bar $formattedPercent%          " -NoNewline -ForegroundColor Green
                }
            }
            # PARSER B: Look for Message Logs to keep the terminal informative
            elseif ($line -match '^MSG:\d+,\d+,\d+,"((?:\\"|[^"])+)') {
                $msg = $matches[1] -replace '\\"', '"'
                
                # Erase the progress bar, print the log, and drop down a line.
                Write-Host "`r                                                                           `r" -NoNewline
                Write-Host "    [MakeMKV] $msg" -ForegroundColor DarkGray
            }
        }
        
        Write-Host "`n"

        if ($LASTEXITCODE -eq 0) {
            Write-Host "  > [SUCCESS] Backup complete!" -ForegroundColor Green
        } else {
            Write-Host "  > [ERROR] MakeMKV encountered a fatal error (Hash/Read failure)." -ForegroundColor Red
            Write-Host "  > [CLEANUP] Purging corrupted backup folder..." -ForegroundColor DarkYellow
            if (Test-Path $backupPath) { Remove-Item -Path $backupPath -Recurse -Force -ErrorAction SilentlyContinue }
            Write-Host "  > [CLEANUP] Purged." -ForegroundColor Green
        }

        Write-Host "  > Ejecting disc tray..." -ForegroundColor DarkGray
        (New-Object -COMObject Shell.Application).Namespace(17).ParseName("$TargetDrive`:").InvokeVerb("Eject")
        Write-Host "=================================================" -ForegroundColor Magenta
        
        Start-Sleep -Seconds 10
    } else {
        # The classic propeller spinner heartbeat
        $frame = $spinner[$counter % 4]
        Write-Host "`r  > Awaiting 4K UHD disc in Drive $($TargetDrive): ... $frame " -NoNewline -ForegroundColor DarkGray
        $counter++
        Start-Sleep -Milliseconds 250
    }
}