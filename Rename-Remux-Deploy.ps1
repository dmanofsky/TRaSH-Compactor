# ==============================================================================
# SCRIPT: The Smart Processor (Rename, Remux, Deploy)
# VERSION: 1.4.1
# PURPOSE: Scans raw backups, queries TMDB, interactive pre-flight checks,
#          auto-detects resolution/HDR, auto-pulls TMDB episode titles, 
#          bulletproof API exception handling, deploys to TrueNAS.
# ==============================================================================

# --- Configuration ---
$tmdbApiKey = "YOUR_TMDB_API_KEY_HERE" # <--- INSERT YOUR KEY HERE
$backupRoot = "D:\media\backups"
$moviesStaging = "D:\media\movies"
$showsStaging = "D:\media\shows"

# TrueNAS Destinations
$truenasMovies = "\\TRUENAS\media\movies"
$truenasShows = "\\TRUENAS\media\shows"
$truenasBackups = "\\TRUENAS\media\backups"

$makemkvExe = "C:\Program Files (x86)\MakeMKV\makemkvcon.exe"

Write-Host "=========================================" -ForegroundColor Magenta
Write-Host "     SMART PROCESSOR (v1.4.1) ONLINE     " -ForegroundColor Magenta
Write-Host "=========================================" -ForegroundColor Magenta

$backups = Get-ChildItem -Path $backupRoot -Directory

if ($backups.Count -eq 0) {
    Write-Host "No backups found in $backupRoot. Exiting." -ForegroundColor Yellow
    exit
}

foreach ($folder in $backups) {
    $volumeName = $folder.Name
    $backupPath = $folder.FullName
    $inputUrl = "file:$backupPath"
    
    Write-Host "`n================================================="
    Write-Host "PROCESSING RAW BACKUP: $volumeName" -ForegroundColor Cyan
    
    $cleanQuery = ($volumeName -replace '_', ' ' -replace 'AC$|UHD$|BLURAY$|DISC\d', '').Trim()

    # ==========================================================================
    # PHASE 1: TMDB INTERACTIVE SEARCH
    # ==========================================================================
    Write-Host "  > Querying TMDB for: '$cleanQuery'..." -ForegroundColor DarkGray
    
    $uri = "https://api.themoviedb.org/3/search/multi?api_key=$tmdbApiKey&query=$cleanQuery&language=en-US&page=1"
    
    # Robust Try/Catch for the Search API
    try {
        $response = Invoke-RestMethod -Uri $uri -ErrorAction Stop
    } catch {
        $response = $null
    }

    if (-not $response -or $response.results.Count -eq 0) {
        Write-Host "  > [WARNING] TMDB found no results or API Key is invalid." -ForegroundColor Yellow
        $cleanQuery = Read-Host "Enter manual search term (or press Enter to skip)"
        if ([string]::IsNullOrWhiteSpace($cleanQuery)) { continue }
        
        $uri = "https://api.themoviedb.org/3/search/multi?api_key=$tmdbApiKey&query=$cleanQuery&language=en-US&page=1"
        try {
            $response = Invoke-RestMethod -Uri $uri -ErrorAction Stop
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
    # PHASE 2: JAVA SCAN & TARGET SELECTION
    # ==========================================================================
    Write-Host "  > Scanning backup structure (Java FPL enabled)..." -ForegroundColor DarkGray
    $debugLogPath = Join-Path $backupRoot "$volumeName-JavaDebug.txt"
    & $makemkvExe -r --cache=1 --debug --messages="$debugLogPath" info $inputUrl | Out-Null
    Start-Sleep -Seconds 1
    
    $scanOutput = Get-Content -Path $debugLogPath -ErrorAction SilentlyContinue
    $parsedTitles = @(); $fplTitleId = -1

    foreach ($line in $scanOutput) {
        if ($line -match 'TINFO:(\d+),.*FPL_MainFeature') { $fplTitleId = [int]$matches[1] }
        if ($line -match 'TINFO:(\d+),9,0,"(\d+):(\d+):(\d+)"') {
            $tId = [int]$matches[1]
            $totalSeconds = ([int]$matches[2] * 3600) + ([int]$matches[3] * 60) + [int]$matches[4]
            $parsedTitles += [PSCustomObject]@{ Id = $tId; Duration = $totalSeconds }
        }
    }

    $targetIds = @()
    $seasonData = $null

    if ($selectedMedia.media_type -eq 'movie') {
        if ($fplTitleId -ne -1) {
            $targetIds += $fplTitleId
        } else {
            $longestTitle = $parsedTitles | Sort-Object Duration -Descending | Select-Object -First 1
            $targetIds += $longestTitle.Id
        }
    } else {
        $episodes = $parsedTitles | Where-Object { $_.Duration -ge 900 -and $_.Duration -le 5400 } | Sort-Object Id
        
        Write-Host "`n  --- TV SHOW DETECTED ---" -ForegroundColor Cyan
        $seasonNum = [int](Read-Host "  > What Season is this disc? (e.g., 1)")
        
        # --- FIX: Robust Try/Catch for the Season API ---
        $seasonUri = "https://api.themoviedb.org/3/tv/$tmdbId/season/$seasonNum?api_key=$tmdbApiKey"
        try {
            $seasonData = Invoke-RestMethod -Uri $seasonUri -ErrorAction Stop
        } catch {
            Write-Host "  > [WARNING] Failed to pull TMDB episode list (Check API Key). Falling back to manual entry." -ForegroundColor Yellow
            $seasonData = $null
        }
        
        Write-Host "`n  > Detected the following possible episodes on disc:" -ForegroundColor Yellow
        foreach ($ep in $episodes) {
            Write-Host "    [ID: $($ep.Id)] - Duration: $([math]::Round($ep.Duration / 60)) mins"
        }
        
        $keepIdsStr = Read-Host "`n  > Enter comma-separated IDs of the TRUE episodes to keep (e.g., 0, 2, 4)"
        $targetIds = $keepIdsStr -split ',' | ForEach-Object { [int]$_.Trim() }
        
        $startingEp = [int](Read-Host "  > What is the starting Episode Number? (e.g., 1)")
    }

    # ==========================================================================
    # PHASE 3: THE PRE-FLIGHT CHECK
    # ==========================================================================
    $plannedFiles = @()
    $tempEp = if ($startingEp) { $startingEp } else { 1 }

    foreach ($id in $targetIds) {
        
        # Auto-Quality Detector
        $res = "1080p" 
        $hdr = ""
        $regexRes = 'SINFO:' + $id + ',0,19,0,"(\d+)x'
        $regexHdr = 'SINFO:' + $id + ',0,.*?(HDR|HDR10|Dolby Vision|BT\.2020|SMPTE2084)'
        
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
            
            # Graceful Fallback: If TMDB didn't return a title, prompt the user
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

    Write-Host "`n  --- PRE-FLIGHT CHECK ---" -ForegroundColor Cyan
    foreach ($plan in $plannedFiles) {
        Write-Host "  Folder : $($plan.LocalFolder)" -ForegroundColor DarkGray
        Write-Host "  File   : $($plan.FileName)" -ForegroundColor Green
    }

    $confirm = Read-Host "`n  > Approve this batch for remuxing and deployment? (Y/n)"
    if ($confirm -match '^[nN]') {
        Write-Host "  > Batch aborted by user. Skipping to next folder..." -ForegroundColor Red
        Remove-Item -Path $debugLogPath -ErrorAction SilentlyContinue
        continue
    }

    # ==========================================================================
    # PHASE 4: REMUX & DEPLOYMENT
    # ==========================================================================
    foreach ($plan in $plannedFiles) {
        if (-not (Test-Path $plan.LocalFolder)) { New-Item -ItemType Directory -Path $plan.LocalFolder | Out-Null }
        Write-Host "`n  > Ripping: $($plan.FileName)" -ForegroundColor Magenta
        
        $filesBefore = @(Get-ChildItem -Path $plan.LocalFolder -Filter "*.mkv")
        & $makemkvExe mkv $inputUrl $plan.Id $plan.LocalFolder | Out-Null
        $filesAfter = @(Get-ChildItem -Path $plan.LocalFolder -Filter "*.mkv")
        $newFile = $filesAfter | Where-Object { $filesBefore.FullName -notcontains $_.FullName }
        
        if ($newFile) { 
            Rename-Item -Path $newFile[0].FullName -NewName $plan.FileName 
            Write-Host "  > Deploying MKV to TrueNAS via Robocopy..." -ForegroundColor Cyan
            $roboArgs = @("$($plan.LocalFolder)", "$($plan.TrueNASFolder)", "$($plan.FileName)", "/MOV", "/J", "/NP")
            & robocopy @roboArgs | Out-Null
        }
    }
    
    $lastLocalFolder = $plannedFiles[-1].LocalFolder
    if ($lastLocalFolder -ne "" -and (Test-Path $lastLocalFolder) -and (Get-ChildItem $lastLocalFolder).Count -eq 0) {
        Remove-Item -Path $lastLocalFolder -Force
        $parentDir = Split-Path $lastLocalFolder
        if ((Test-Path $parentDir) -and (Get-ChildItem $parentDir).Count -eq 0) { Remove-Item -Path $parentDir -Force }
    }

    # ==========================================================================
    # PHASE 5: RAW BACKUP DEPLOYMENT
    # ==========================================================================
    Write-Host "  > Moving raw backup folder to TrueNAS Backups share..." -ForegroundColor Cyan
    $nasBackupDir = Join-Path $truenasBackups $volumeName
    $roboBackupArgs = @("$backupPath", "$nasBackupDir", "/E", "/MOVE", "/J", "/NP")
    & robocopy @roboBackupArgs | Out-Null
    Remove-Item -Path $debugLog.Path -ErrorAction SilentlyContinue
    Write-Host "================================================="
    Write-Host "Finished processing $finalTitle! The raw backup and MKVs have been moved to TrueNAS." -ForegroundColor Green
}