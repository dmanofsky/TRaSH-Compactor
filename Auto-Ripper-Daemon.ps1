# ==============================================================================
# SCRIPT 1: AUTO-RIPPER DAEMON (The "Dumb" Ingest)
# PURPOSE: Runs endlessly in the background. Watches the optical drive. 
#          When a disc is inserted, it rips the raw files to the NVMe, 
#          ejects the tray, and waits for the next disc. 
# ==============================================================================

# --- Configuration (CHANGE THESE PER DRIVE) ---
$opticalDrive = "I"             # The Windows drive letter (e.g., I, J, K)
$discId = "disc:0"              # MakeMKV's internal ID (disc:0, disc:1, etc.)
# ----------------------------------------------

$backupRoot = "D:\media\backups"
$makemkvExe = "C:\Program Files (x86)\MakeMKV\makemkvcon.exe"

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host " INGEST DAEMON ($opticalDrive`: -> $discId) ONLINE " -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

$fso = New-Object -ComObject Scripting.FileSystemObject

while ($true) {
    $drive = $fso.GetDrive("$opticalDrive`:")
    
    if ($drive.IsReady) {
        $volumeName = $drive.VolumeName
        if ([string]::IsNullOrWhiteSpace($volumeName)) { $volumeName = "UNKNOWN_DISC_$(Get-Date -Format 'yyyyMMdd_HHmmss')" }
        
        $backupPath = Join-Path $backupRoot $volumeName
        
        if (Test-Path $backupPath) {
            Write-Host "  > [SKIP] $volumeName is already backed up." -ForegroundColor DarkGray
            Start-Sleep -Seconds 30
            continue
        }

        Write-Host "`nDISC DETECTED: $volumeName" -ForegroundColor Yellow
        Write-Host "  > Ripping Decrypted Backup to NVMe..." -ForegroundColor Cyan
        
        New-Item -ItemType Directory -Path $backupPath | Out-Null
        
        # --- THE PARAMETERIZED COMMAND ---
        # Notice how $discId perfectly drops into the execution string
        & $makemkvExe backup --decrypt --cache=1 $discId $backupPath
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  > [SUCCESS] Backup complete!" -ForegroundColor Green
            Write-Host "  > Ejecting disc tray..." -ForegroundColor DarkGray
            (New-Object -COMObject Shell.Application).Namespace(17).ParseName("$opticalDrive`:").InvokeVerb("Eject")
        } else {
            Write-Host "  > [ERROR] MakeMKV Backup failed. Please check the disc." -ForegroundColor Red
        }
    }
    
    Start-Sleep -Seconds 10
}