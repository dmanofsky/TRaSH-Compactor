# ==============================================================================
# SCRIPT: The Smart Processor (Rename, Remux, Deploy)
# VERSION: 1.5.2
# PURPOSE: Master Batch Queuing, GUI-style MakeMKV terminal output,
#          bulletproof HDR fallback logic for UHD discs, auto-pulls TMDB 
#          episode titles, bypasses API bot-blocks, deploys to TrueNAS.
# ==============================================================================

# --- Configuration ---
$tmdbApiKey = "YOUR_NEW_API_KEY_HERE" # <--- INSERT YOUR NEW KEY HERE
$backupRoot = "D:\media\backups"
$moviesStaging = "D:\media\movies"
$showsStaging = "D:\media\shows"

# TrueNAS Destinations
$truenasMovies = "\\TRUENAS\media\movies"
$truenasShows = "\\TRUENAS\media\shows"
$truenasBackups = "\\TRUENAS\media\backups"

$makemkvExe = "C:\Program Files (x86)\MakeMKV\makemkvcon.exe"
$browserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

Write-Host "=========================================" -ForegroundColor Magenta
Write-Host "  SMART BATCH PROCESSOR (v1.5.2) ONLINE  " -ForegroundColor Magenta
Write-Host "=========================================" -ForegroundColor Magenta

$backups = Get-ChildItem -Path $backupRoot -Directory

if ($backups.Count -eq 0) {
    Write-Host "No backups found in $backupRoot. Exiting." -ForegroundColor Yellow
    exit
}

# The Master Queue holds all jobs until the user approves the entire batch
$MasterQueue = @()

foreach ($folder in $backups) {
    $volumeName = $folder.Name
    $backupPath = $folder.FullName
    $inputUrl = "file:$backupPath"
    
    Write-Host "`n================================================="
    Write-Host "PLANNING RAW BACKUP: $volumeName" -ForegroundColor Cyan
    
    $cleanQuery = ($volumeName -replace '_', ' ' -replace 'AC$|UHD$|BLURAY$|DISC\d', '').Trim()

    # ==========================================================================
    # PHASE 1: TMDB INTERACTIVE SEARCH
    # ==========================================================================
    Write-Host "  > Querying TMDB for: '$cleanQuery'..." -ForegroundColor DarkGray
    
    $uri = "https://api.themoviedb.org/3/search/multi?api_key=$tmdbApiKey&query=$cleanQuery&language=en-US&page=1"
    
    try {
        $response = Invoke-RestMethod -Uri $uri -UserAgent $browserAgent -ErrorAction Stop
    } catch {
        $response = $null
    }

    if (-not $response -or $response.results.Count -eq 0) {
        Write-Host "  > [WARNING] TMDB found no results." -ForegroundColor Yellow
        $cleanQuery = Read-Host "Enter manual search term (or press Enter to skip)"
        if ([string]::IsNullOrWhiteSpace($cleanQuery)) { continue }
        
        $uri = "https://api.themoviedb.org/3/search/multi?api_key=$tmdbApiKey&query=$cleanQuery&language=en-US&page=1"
        try {
            $response = Invoke-RestMethod -Uri $uri -UserAgent $browserAgent -ErrorAction Stop
        } catch {
            Write-Host "  > [ERROR] TMDB request failed. Check internet or API key." -ForegroundColor Red
            continue
        }
    }

    $results = $response.results | Select-Object -First 5
    Write-Host "`n  --- TMDB Results ---" -ForegroundColor Yellow
    for ($i = 0; $i -lt $results.Count; $i++) {
        $item = $results[$i]
        $title = if ($item.media_type -eq 'movie') { $item.title } else { $item.name }
        $date = if ($item.media_type -eq 'movie') { $item.release_date } else { $item.first_air_date }
        $year = if ($date) { $date.Substring(0,4) } else { "Unknown" }
        Write-Host "  [$($i + 1)] [$($item.media_type.ToUpper())] $title ($year)"
    }
    Write-Host "  [0] Skip this folder entirely."

    $selection = Read-Host "`nSelect the correct match (0-$($results.Count))"
    if ($selection -eq '0' -or [string]::IsNullOrWhiteSpace($selection)) {
        Write-Host "  > Skipping $volumeName." -ForegroundColor DarkGray
        continue
    }

    $chosenIndex = [int]$selection - 1
    $selectedMedia = $results[$chosenIndex]
    
    $finalTitle = if ($selectedMedia.media_type -eq 'movie') { $selectedMedia.title } else { $selectedMedia.name }
    $finalTitle = $finalTitle -replace '[\\/:*?"<>|]', '' 
    $finalDate = if ($selectedMedia.media_type -eq 'movie') { $selectedMedia.release_date } else { $selectedMedia.first_air_date }
    $finalYear = if ($finalDate) { $finalDate.Substring(0,4) } else { "" }
    $tmdbId = $selectedMedia.id 

    Write-Host "  > Locked in: $finalTitle ($finalYear) {tmdb-$tmdbId}" -ForegroundColor Green

    # ==========================================================================
    # PHASE 2: JAVA SCAN & DEEP METADATA EXTRACTION
    # ==========================================================================
    Write-Host "  > Scanning backup structure (Java FPL enabled)..." -ForegroundColor DarkGray
    $debugLogPath = Join-Path $backupRoot "$volumeName-JavaDebug.txt"
    & $makemkvExe -r --cache=1 --debug --messages="$debugLogPath" info $inputUrl | Out-Null
    Start-Sleep -Seconds 1
    
    $scanOutput = Get-Content -Path $debugLogPath -ErrorAction SilentlyContinue
    $titleData = @{}
    $fplTitleId = -1

    foreach ($line in $scanOutput) {
        if ($line -match 'TINFO:(\d+),.*FPL_MainFeature') { $fplTitleId = [int]$matches[1] }
        
        if ($line -match 'TINFO:(\d+),(\d+),0,"([^"]+)"') {
            $tId = [int]$matches[1]
            $code = [int]$matches[2]
            $val = $matches[3]
            
            if (-not $titleData.ContainsKey($tId)) { 
                $titleData[$tId] = @{ Id = $tId; Chapters = "1"; SizeStr = "Unknown"; DurationStr = "0:00:00"; Duration = 0 } 
            }
            
            if ($code -eq 8) { $titleData[$tId].Chapters = $val }
            if ($code -eq 10) { $titleData[$tId].SizeStr = $val }
            if ($code -eq 9) { 
                $titleData[$tId].DurationStr = $val 
                $parts = $val -split ':'
                if ($parts.Length -eq 3) {
                    $titleData[$tId].Duration = ([int]$parts[0] * 3600) + ([int]$parts[1] * 60) + [int]$parts[2]
                }
            }
        }
    }

    $targetIds = @()
    $seasonData = $null

    if ($selectedMedia.media_type -eq 'movie') {
        if ($fplTitleId -ne -1) {
            $targetIds += $fplTitleId
        } else {
            $longestTitle = $titleData.Values | Sort-Object Duration -Descending | Select-Object -First 1
            $targetIds += $longestTitle.Id
        }
    } else {
        $episodes = $titleData.Values | Where-Object { $_.Duration -ge 900 -and $_.Duration -le 5400 } | Sort-Object Id
        
        Write-Host "`n  --- TV SHOW DETECTED ---" -ForegroundColor Cyan
        $seasonNum = [int](Read-Host "  > What Season is this disc? (e.g., 1)")
        
        $seasonUri = "https://api.themoviedb.org/3/tv/{0}/season/{1}?api_key={2}" -f $tmdbId, $seasonNum, $tmdbApiKey
        try {
            $seasonData = Invoke-RestMethod -Uri $seasonUri -UserAgent $browserAgent -ErrorAction Stop
        } catch {
            Write-Host "  > [WARNING] Failed to pull TMDB episode list. Falling back to manual entry." -ForegroundColor Yellow
            $seasonData = $null
        }
        
        Write-Host "`n  > Detected the following possible episodes on disc:" -ForegroundColor Yellow
        foreach ($ep in $episodes) {
            Write-Host "    [ID: $($ep.Id)] - $($ep.Chapters) chapter(s) , $($ep.SizeStr) (Duration: $($ep.DurationStr))"
        }
        
        $keepIdsStr = Read-Host "`n  > Enter comma-separated IDs of the TRUE episodes to keep (e.g., 0, 2, 4)"
        $targetIds = $keepIdsStr -split ',' | ForEach-Object { [int]$_.Trim() }
        
        $startingEp = [int](Read-Host "  > What is the starting Episode Number? (e.g., 1)")
    }

    # ==========================================================================
    # PHASE 3: QUALITY DETECTION & NAMING
    # ==========================================================================
    $plannedFiles = @()
    $tempEp = if ($startingEp) { $startingEp } else { 1 }

    foreach ($id in $targetIds) {
        
        $res = "1080p" 
        $hdr = ""
        
        # Expanded Regex to catch the 10-bit HEVC profile used for HDR
        $regexRes = '^SINFO:' + $id + ',\d+,19,\d+,"(\d+)x'
        $regexHdr = '(?i)^SINFO:' + $id + ',\d+,.*?(HDR|Dolby Vision|BT\.?2020|SMPTE|Main 10)'
        
        foreach ($line in $scanOutput) {
            if ($line -match $regexRes) {
                $width = [int]$matches[1]
                if ($width -ge 3200) { $res = "2160p" }
                elseif ($width -ge 1900) { $res = "1080p" }
                elseif ($width -ge 1200) { $res = "720p" }
                else { $res = "480p" }
            }
            if ($line -match $regexHdr) { $hdr = " HDR" }
        }

        # --- FIX: The "Dumb Disc" Fallback ---
        # If MakeMKV's quick-scan skipped the deep colorimetry packets, we 
        # force the HDR tag for 2160p because all raw 4K rips are HDR natively.
        if ($res -eq "2160p" -and $hdr -eq "") {
            $hdr = " HDR"
        }
        
        $qualitySuffix = "$res Remux$hdr"
        
        if ($selectedMedia.media_type -eq 'movie') {
            $folderName = "$finalTitle ($finalYear) {tmdb-$tmdbId}"
            $fileName = "$finalTitle ($finalYear) {tmdb-$tmdbId} - $qualitySuffix.mkv"
            $localTargetDir = Join-Path $moviesStaging $folderName
            $truenasTargetDir = Join-Path $truenasMovies $folderName
        } else {
            $folderName = "$finalTitle ($finalYear) {tmdb-$tmdbId}"
            $seasonFolder = "Season $($seasonNum.ToString('D2'))"
            
            $epTitle = ""
            if ($seasonData -and $seasonData.episodes) {
                $tmdbEp = $seasonData.episodes | Where-Object { $_.episode_number -eq $tempEp }
                if ($tmdbEp) { $epTitle = $tmdbEp.name }
            }
            
            if ([string]::IsNullOrWhiteSpace($epTitle)) {
                $epTitle = Read-Host "    > Enter Episode Title for S$($seasonNum.ToString('D2'))E$($tempEp.ToString('D2')) (Leave blank to skip)"
            }
            
            if ([string]::IsNullOrWhiteSpace($epTitle)) {
                $fileName = "$finalTitle - S$($seasonNum.ToString('D2'))E$($tempEp.ToString('D2')) - $qualitySuffix.mkv"
            } else {
                $cleanEpTitle = $epTitle -replace '[\\/:*?"<>|]', '' 
                $fileName = "$finalTitle - S$($seasonNum.ToString('D2'))E$($tempEp.ToString('D2')) - $cleanEpTitle - $qualitySuffix.mkv"
            }
            
            $localTargetDir = Join-Path (Join-Path $showsStaging $folderName) $seasonFolder
            $truenasTargetDir = Join-Path (Join-Path $truenasShows $folderName) $seasonFolder
            $tempEp++
        }

        $plannedFiles += [PSCustomObject]@{ Id = $id; LocalFolder = $localTargetDir; TrueNASFolder = $truenasTargetDir; FileName = $fileName }
    }

    $MasterQueue += [PSCustomObject]@{
        VolumeName = $volumeName
        BackupPath = $backupPath
        InputUrl = $inputUrl
        LogPath = $debugLogPath
        Plans = $plannedFiles
    }
}

# ==========================================================================
# PHASE 4: THE MASTER PRE-FLIGHT CHECK
# ==========================================================================
if ($MasterQueue.Count -eq 0) { exit }

Write-Host "`n=================================================" -ForegroundColor Magenta
Write-Host "         MASTER PRE-FLIGHT CHECK                 " -ForegroundColor Magenta
Write-Host "=================================================" -ForegroundColor Magenta

foreach ($job in $MasterQueue) {
    Write-Host "`n  [DISC: $($job.VolumeName)]" -ForegroundColor Yellow
    foreach ($plan in $job.Plans) {
        Write-Host "  Folder : $($plan.LocalFolder)" -ForegroundColor DarkGray
        Write-Host "  File   : $($plan.FileName)" -ForegroundColor Green
    }
}

$confirm = Read-Host "`n> APPROVE MASTER WORK ORDER for remuxing and deployment? (Y/n)"
if ($confirm -match '^[nN]') {
    Write-Host "> Work order aborted. Exiting." -ForegroundColor Red
    foreach ($job in $MasterQueue) { Remove-Item -Path $job.LogPath -ErrorAction SilentlyContinue }
    exit
}

# ==========================================================================
# PHASE 5: BATCH EXECUTION (Remux, Deploy, Cleanup)
# ==========================================================================
foreach ($job in $MasterQueue) {
    Write-Host "`n================================================="
    Write-Host "EXECUTING JOB: $($job.VolumeName)" -ForegroundColor Cyan
    
    foreach ($plan in $job.Plans) {
        if (-not (Test-Path $plan.LocalFolder)) { New-Item -ItemType Directory -Path $plan.LocalFolder | Out-Null }
        Write-Host "  > Ripping: $($plan.FileName)" -ForegroundColor Magenta
        
        $filesBefore = @(Get-ChildItem -Path $plan.LocalFolder -Filter "*.mkv")
        & $makemkvExe mkv $job.InputUrl $plan.Id $plan.LocalFolder | Out-Null
        $filesAfter = @(Get-ChildItem -Path $plan.LocalFolder -Filter "*.mkv")
        $newFile = $filesAfter | Where-Object { $filesBefore.FullName -notcontains $_.FullName }
        
        if ($newFile) { 
            Rename-Item -Path $newFile[0].FullName -NewName $plan.FileName 
            Write-Host "  > Deploying MKV to TrueNAS via Robocopy..." -ForegroundColor Cyan
            $roboArgs = @("$($plan.LocalFolder)", "$($plan.TrueNASFolder)", "$($plan.FileName)", "/MOV", "/J", "/NP")
            & robocopy @roboArgs | Out-Null
        }
    }
    
    if ($job.Plans.Count -gt 0) {
        $lastLocalFolder = $job.Plans[-1].LocalFolder
        if ($lastLocalFolder -ne "" -and (Test-Path $lastLocalFolder) -and (Get-ChildItem $lastLocalFolder).Count -eq 0) {
            Remove-Item -Path $lastLocalFolder -Force
            $parentDir = Split-Path $lastLocalFolder
            if ((Test-Path $parentDir) -and (Get-ChildItem $parentDir).Count -eq 0) { Remove-Item -Path $parentDir -Force }
        }
    }

    Write-Host "  > Moving raw backup folder to TrueNAS Backups share..." -ForegroundColor Cyan
    $nasBackupDir = Join-Path $truenasBackups $job.VolumeName
    $roboBackupArgs = @("$($job.BackupPath)", "$nasBackupDir", "/E", "/MOVE", "/J", "/NP")
    & robocopy @roboBackupArgs | Out-Null
    
    Remove-Item -Path $job.LogPath -ErrorAction SilentlyContinue
    Write-Host "Finished Job: $($job.VolumeName)" -ForegroundColor Green
}

Write-Host "`n=================================================" -ForegroundColor Magenta
Write-Host "  BATCH QUEUE COMPLETE. ALL JOBS DEPLOYED.       " -ForegroundColor Magenta
Write-Host "=================================================" -ForegroundColor Magenta