# Získání klíčových slov
$kwds = Read-Host "Kličová slova oddělená čárkou"
$newKeywords = $kwds -split ',' | ForEach-Object { $_.Trim() }

# Maximální počet paralelních jobů
$maxConcurrentJobs = 4
$allFiles = $args
$totalFiles = $allFiles.Count
$jobs = @{}
$fileIndex = 0
$completedCount = 0
$failedCount = 0

Write-Host "Zpracovávám $totalFiles souborů, maximálně $maxConcurrentJobs najednou..."
Write-Host ""

# Inicializace progress baru pro celkový průběh
Write-Progress -Activity "Zpracování souborů" -Status "Inicializace..." -PercentComplete 0

while (($fileIndex -lt $totalFiles) -or ($jobs.Count -gt 0)) {
    # Spouštění nových jobů, pokud je místo a jsou ještě soubory ke zpracování
    while (($jobs.Count -lt $maxConcurrentJobs) -and ($fileIndex -lt $totalFiles)) {
        $file = $allFiles[$fileIndex]
        $currentFileNumber = $fileIndex + 1
        $fileIndex++
        
        # Progress bar pro aktuální soubor
        Write-Progress -Id 1 -Activity "Spouštím soubor $currentFileNumber z $totalFiles" -Status "Start: $(Split-Path $file -Leaf)" -PercentComplete (($currentFileNumber - 1) / $totalFiles * 100)
        
        # Zpracování podle přípony
        if ($file -like "*.jpg" -or $file -like "*.jpeg") {
            $job = Start-Job -ScriptBlock {
                param($f, $k, $fileNum, $total)
                try {
                    # Úplné potlačení všeho výstupu (stdout i stderr)
                    $null = & exiftool -Keywords+="$k" -overwrite_original -P $f 2>&1
                    return @{File = $f; Status = "OK"; Message = "JPG zpracován"}
                } catch {
                    return @{File = $f; Status = "FAIL"; Message = $_.Exception.Message}
                }
            } -ArgumentList $file, $kwds, $currentFileNumber, $totalFiles
            $jobs[$job.Id] = @{File = $file; Number = $currentFileNumber; Type = "JPG"}
        }
        elseif ($file -like "*.mp4") {
            $job = Start-Job -ScriptBlock {
                param($f, $newKws, $fileNum, $total)
                try {
                    $xmpFile = [System.IO.Path]::ChangeExtension($f, "xmp")
                    
                    # Zjistíme existující klíčová slova, pokud XMP soubor existuje
                    $existingKeywords = @()
                    if (Test-Path $xmpFile) {
                        # Potlačení chyb při čtení XMP
                        $output = & exiftool -XMP-dc:subject $xmpFile 2>$null
                        if ($output -match "Subject\s*:\s*(.+)") {
                            $existingKeywords = $matches[1] -split ',\s*'
                        }
                    }
                    
                    # Spojení existujících a nových klíčových slov
                    $allKeywords = ($existingKeywords + $newKws) | Select-Object -Unique
                    $keywordsString = $allKeywords -join ';'
                    
                    # Vytvoření/aktualizace XMP souboru s úplným potlačením výstupu
                    if (Test-Path $xmpFile) {
                        # Přesměrování stderr do stdout a obojí do $null
                        $null = & exiftool -m -sep ", " "-XMP-dc:subject=$keywordsString" $xmpFile -overwrite_original 2>&1
                    } else {
                        $null = & exiftool -m -sep ", " "-XMP-dc:subject=$keywordsString" $f -o $xmpFile -overwrite_original 2>&1
                    }
                    
                    # Kopírování časových značek s potlačením výstupu
                    $null = & exiftool -TagsFromFile $f "-FileModifyDate<FileModifyDate" "-FileCreateDate<FileCreateDate" $xmpFile 2>&1
                    
                    # Potlačení všech warningů z exiftool
                    $env:EXIFTOOL_VERBOSE = 0
                    
                    return @{File = $f; Status = "OK"; Message = "MP4 zpracován"}
                } catch {
                    return @{File = $f; Status = "FAIL"; Message = $_.Exception.Message}
                }
            } -ArgumentList $file, $newKeywords, $currentFileNumber, $totalFiles
            $jobs[$job.Id] = @{File = $file; Number = $currentFileNumber; Type = "MP4"}
        }
    }
    
    # Kontrola dokončených jobů
    if ($jobs.Count -gt 0) {
        $completed = Wait-Job -Job ($jobs.Keys | ForEach-Object { Get-Job -Id $_ }) -Any -Timeout 1
        
        foreach ($job in $completed) {
            # Získání výsledku - potlačení chybových výstupů z jobů
            $result = Receive-Job -Job $job 2>&1
            $jobInfo = $jobs[$job.Id]
            
            # Kontrola, zda result obsahuje náš objekt nebo je to chybový výstup
            if ($result -is [Hashtable] -and $result.ContainsKey("Status")) {
                if ($result.Status -eq "OK") {
                    $completedCount++
                    # Write-Host "✅ $($jobInfo.File) - OK" -ForegroundColor Green
                } else {
                    $failedCount++
                    Write-Host "❌ $($jobInfo.File) - Chyba: $($result.Message)" -ForegroundColor Red
                }
            } else {
                # Pokud přišel jen warning, bereme to jako úspěch
                $completedCount++
                Write-Host "✅ $($jobInfo.File) - OK (s warningy)" -ForegroundColor Yellow
            }
            
            Remove-Job -Job $job
            $jobs.Remove($job.Id)
            
            # Aktualizace progress baru
            $percentComplete = ($completedCount / $totalFiles) * 100
            $activeInfo = "Aktivní: $($jobs.Count)/$maxConcurrentJobs | Hotovo: $completedCount | Chyby: $failedCount"
            
            Write-Progress -Activity "Zpracování souborů" -Status $activeInfo -PercentComplete $percentComplete -CurrentOperation "Dokončen: $(Split-Path $jobInfo.File -Leaf)"
        }
    }
    
    # Krátká pauza
    Start-Sleep -Milliseconds 100
}

# Dokončení progress baru
Write-Progress -Activity "Zpracování souborů" -Status "Dokončeno" -PercentComplete 100 -Completed

# Konečné shrnutí
Write-Host ""
Write-Host "=" * 50
Write-Host "SHRNUTÍ:" -ForegroundColor Cyan
Write-Host "Celkem souborů: $totalFiles" -ForegroundColor White
Write-Host "Úspěšně zpracováno: $completedCount" -ForegroundColor Green
if ($failedCount -gt 0) {
    Write-Host "Chyb: $failedCount" -ForegroundColor Red
}
Write-Host "=" * 50
Write-Host ""

# Odpočet 3 sekund
#for ($i = 3; $i -ge 1; $i--) {
#    Write-Host "`rSkript bude ukončen za $i sekund..." -ForegroundColor Yellow -NoNewline
#    Start-Sleep -Seconds 1
#}
#Write-Host "`rHotovo!                                    " -ForegroundColor Green
