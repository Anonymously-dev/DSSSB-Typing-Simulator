# DSSSB LDC Typing Evaluation Simulator
# Author: Verma_Ji
# Description: A GUI-based typing test evaluator that calculates strokes, WPM, and errors.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase

# Initialize a text control early to prevent High-DPI scaling UI issues
$script:DpiPreWake = New-Object System.Windows.Controls.TextBox
[System.Windows.Forms.Application]::EnableVisualStyles()

# =======================================================================================
# Global Application States & Variables
# =======================================================================================
$script:AppMode = "Dictionary"
$script:UnitMode = "Words"
$script:DictEngineType = "Native"

$script:HasRun = $false
$script:LastGrossStrokes = 0
$script:LastNetStrokes = 0
$script:LastErrorStrokes = 0
$script:LastGrossWords = 0
$script:LastNetWords = 0
$script:LastErrorWords = 0
$script:LastScale = 2.0
$script:LastDuration = 10.0

$script:CurrentErrorObjects = @()
$script:IgnoredErrorIndices = @()

$script:IsFreeHandActive = $false
$script:IsTestRunning = $false
$script:FreeHandSecondsLeft = 0
$script:FreeHandTotalSeconds = 0
$script:CountdownSeconds = 0
$script:BackspaceCount = 0

# Tooltip settings for UI elements
$script:balloonTip = New-Object System.Windows.Forms.ToolTip
$script:balloonTip.IsBalloon = $true
$script:balloonTip.InitialDelay = 1400  
$script:balloonTip.ReshowDelay = 500
$script:balloonTip.AutoPopDelay = 6000 

# =======================================================================================
# Embedded Assets (Base64 Audio & Images)
# =======================================================================================

# Paste background track Base64 here:
$script:Base64Music = ""

# Paste mechanical typing click WAV Base64 data here:
$script:Base64TypingSound = ""

# Paste graphic asset Base64 here:
$script:Base64Logo = ""


# =======================================================================================
# Audio Players Setup
# =======================================================================================

# 1. Background Distraction Noise Player Setup
$script:IsDistractionPlaying = $false
$script:NoisePlayer = $null
try {
    $script:NoisePlayer = New-Object -ComObject WMPlayer.OCX
} catch {}

$script:TempAudioPath = Join-Path $env:TEMP "dsssb_exam_noise.dat"

if ($script:Base64Audio.Length -gt 100 -and $null -ne $script:NoisePlayer) {
    try {
        $cleanBase64 = $script:Base64Audio -replace "[^a-zA-Z0-9+/=]", ""
        $audioBytes = [System.Convert]::FromBase64String($cleanBase64)
        [IO.File]::WriteAllBytes($script:TempAudioPath, $audioBytes)
        
        $script:NoisePlayer.URL = $script:TempAudioPath
        $script:NoisePlayer.settings.setMode("loop", $true)
        $script:NoisePlayer.controls.stop()
    } catch {}
}

# 2. Typing Sound Effect Player Setup
$script:InternalTypingWavPath = Join-Path $env:TEMP "dsssb_typing_click.wav"
$script:SystemSoundPlayer = New-Object System.Media.SoundPlayer

# Timer to stop the typing loop when the user pauses
$script:IsTypingLoopPlaying = $false
$script:TypingStopTimer = New-Object System.Windows.Forms.Timer
$script:TypingStopTimer.Interval = 10000 
$script:TypingStopTimer.Add_Tick({
    $script:TypingStopTimer.Stop()
    $script:IsTypingLoopPlaying = $false
    try { $script:SystemSoundPlayer.Stop() } catch {}
})

# Triggers the typing sound effect based on keypresses
function Invoke-StagedTypingSound {
    if (-not $script:IsDistractionPlaying) { 
        $script:TypingStopTimer.Stop()
        $script:IsTypingLoopPlaying = $false
        try { $script:SystemSoundPlayer.Stop() } catch {}
        return 
    }

    if ([string]::IsNullOrWhiteSpace($script:Base64TypingSound)) { return }
    
    if (-not (Test-Path $script:InternalTypingWavPath)) {
        try {
            $bytes = [System.Convert]::FromBase64String($script:Base64TypingSound)
            [IO.File]::WriteAllBytes($script:InternalTypingWavPath, $bytes)
            $script:SystemSoundPlayer.SoundLocation = $script:InternalTypingWavPath
            $script:SystemSoundPlayer.Load()
        } catch { return }
    }

    $script:TypingStopTimer.Stop()
    $script:TypingStopTimer.Start()

    if (-not $script:IsTypingLoopPlaying) {
        $script:IsTypingLoopPlaying = $true
        try { $script:SystemSoundPlayer.PlayLooping() } catch {}
    }
}

# Form cleanup routine (deletes temp files and stops audio on close)
$form_FormClosing = {
    try {
        if ($null -ne $LiveTimer) { $LiveTimer.Stop(); $LiveTimer.Dispose() }
        if ($null -ne $script:TypingStopTimer) { $script:TypingStopTimer.Stop(); $script:TypingStopTimer.Dispose() }
        if ($script:NoisePlayer) { $script:NoisePlayer.controls.stop() }
        if (Test-Path $script:TempAudioPath) { Remove-Item $script:TempAudioPath -Force }
        if (Test-Path $script:InternalTypingWavPath) { Remove-Item $script:InternalTypingWavPath -Force }
        $musicPath = Join-Path $env:TEMP "gta4_popup_music.wav"
        if (Test-Path $musicPath) { Remove-Item $musicPath -Force }
    } catch {}
}

# =======================================================================================
# Core Evaluation Engines
# =======================================================================================

# UI Helper: Draws rounded corners on form controls
function Invoke-PaintRoundedCorners {
    param($sender, $e, $radius, $borderColor, $fillColor)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    
    $d = $radius * 2
    if ($sender.Width -le $d -or $sender.Height -le $d) { return }
    
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $rect = New-Object System.Drawing.Rectangle(0, 0, ($sender.Width - 1), ($sender.Height - 1))
    
    $path.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
    $path.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 90)
    $path.AddArc($rect.Right - $d, $rect.Bottom - $d, $d, $d, 0, 90)
    $path.AddArc($rect.X, $rect.Bottom - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    
    if ($fillColor) {
        $brush = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml($fillColor))
        $g.FillPath($brush, $path)
        $brush.Dispose()
    }
    
    if ($borderColor) {
        $pen = New-Object System.Drawing.Pen([System.Drawing.ColorTranslator]::FromHtml($borderColor), 1)
        $g.DrawPath($pen, $path)
        $pen.Dispose()
    }
    $path.Dispose()
}

# Text Engine 1: Comparison Mode (Checks typed text against a master reference text)
function Run-ComparisonEngine {
    param([string]$TypedText, [string]$MasterText)
    
    $masterMatches = [regex]::Matches($MasterText, "\S+")
    $typedMatches = [regex]::Matches($TypedText, "\S+")
    $errorList = New-Object System.Collections.ArrayList
    
    $m = 0
    $t = 0
    $maxLookahead = 40

    while ($t -lt $typedMatches.Count) {
        [System.Windows.Forms.Application]::DoEvents()
        
        # Perfect match
        if ($m -lt $masterMatches.Count -and $masterMatches[$m].Value -ceq $typedMatches[$t].Value) {
            $m++
            $t++
            continue
        }
        
        # Case mismatch or typo on the exact same word
        if ($m -lt $masterMatches.Count -and $masterMatches[$m].Value -eq $typedMatches[$t].Value) {
            $errLen = $typedMatches[$t].Length
            [void]$errorList.Add([PSCustomObject]@{ 
                Type = "Mismatch"
                Text = "Typo/Case Error: '$($typedMatches[$t].Value)' (Expected: '$($masterMatches[$m].Value)')"
                StrokePen = 5
                WordPen = 1
                DisplayErrorCount = 5
                Index = $typedMatches[$t].Index
                Length = $errLen 
            })
            $m++
            $t++
            continue
        }

        # Lookahead to detect omitted words
        $bestAnchorIndex = -1
        $lowestOmissionPenalty = $maxLookahead
        
        for ($look = 1; $look -le $maxLookahead; $look++) {
            $mCheck = $m + $look
            if ($mCheck -lt $masterMatches.Count) {
                if ($masterMatches[$mCheck].Value -ceq $typedMatches[$t].Value) {
                    $confidence = 1
                    if (($mCheck + 1 -lt $masterMatches.Count) -and ($t + 1 -lt $typedMatches.Count) -and ($masterMatches[$mCheck + 1].Value -ceq $typedMatches[$t + 1].Value)) { $confidence++ }
                    if (($mCheck + 2 -lt $masterMatches.Count) -and ($t + 2 -lt $typedMatches.Count) -and ($masterMatches[$mCheck + 2].Value -ceq $typedMatches[$t + 2].Value)) { $confidence++ }
                    
                    if ($confidence -ge 2 -or ($confidence -eq 1 -and $look -le 2 -and $look -lt $lowestOmissionPenalty)) {
                        $lowestOmissionPenalty = $look
                        $bestAnchorIndex = $mCheck
                        if ($confidence -ge 2) { break }
                    }
                }
            }
        }
        
        # Log omitted words
        if ($bestAnchorIndex -ne -1) {
            $skippedWordsCount = $bestAnchorIndex - $m
            $skippedArray = @()
            for ($i = 0; $i -lt $skippedWordsCount; $i++) { $skippedArray += $masterMatches[$m + $i].Value }
            $skippedPhrase = $skippedArray -join " "
            
            [void]$errorList.Add([PSCustomObject]@{ 
                Type = "Omission"
                Text = "Omission: Skipped $skippedWordsCount word(s) -> '$skippedPhrase'"
                StrokePen = (5 * $skippedWordsCount) 
                WordPen = $skippedWordsCount         
                DisplayErrorCount = (5 * $skippedWordsCount)
                Index = -1
                Length = 0 
            })
            $m = $bestAnchorIndex + 1
            $t++
         } else {
            # Lookahead to detect extra inserted words
            $insertionFound = -1
            for ($lookT = 1; $lookT -le 5; $lookT++) {
                if (($t + $lookT -lt $typedMatches.Count) -and ($m -lt $masterMatches.Count) -and ($masterMatches[$m].Value -ceq $typedMatches[$t + $lookT].Value)) {
                    $insertionFound = $lookT
                    break
                }
            }

            # Log inserted words
            if ($insertionFound -ne -1) {
                for ($extra = 0; $extra -lt $insertionFound; $extra++) {
                    $errLen = $typedMatches[$t + $extra].Length
                    [void]$errorList.Add([PSCustomObject]@{ 
                        Type = "Insertion"
                        Text = "Extra Word: '$($typedMatches[$t + $extra].Value)'"
                        StrokePen = 5
                        WordPen = 1
                        DisplayErrorCount = 5
                        Index = $typedMatches[$t + $extra].Index
                        Length = $errLen 
                    })
                }
                $t += $insertionFound
            } else {
                # Fallback: Just mark it as a general typo/mismatch
                if ($m -lt $masterMatches.Count) {
                    $errLen = $typedMatches[$t].Length
                    [void]$errorList.Add([PSCustomObject]@{ 
                        Type = "Mismatch"
                        Text = "Typo/Case Error: '$($typedMatches[$t].Value)' (Expected: '$($masterMatches[$m].Value)')"
                        StrokePen = 5
                        WordPen = 1
                        DisplayErrorCount = 5
                        Index = $typedMatches[$t].Index
                        Length = $errLen 
                    })
                    $m++
                    $t++
                } else {
                    $errLen = $typedMatches[$t].Length
                    [void]$errorList.Add([PSCustomObject]@{ 
                        Type = "Insertion"
                        Text = "Extra Word: '$($typedMatches[$t].Value)'"
                        StrokePen = 5
                        WordPen = 1
                        DisplayErrorCount = 5
                        Index = $typedMatches[$t].Index
                        Length = $errLen 
                    })
                    $t++
                }
            }
        }
    }

    # Catch extra spacing errors
    foreach ($match in [regex]::Matches($TypedText, " {2,}")) { 
        $extraSpaceCount = ($match.Length - 1)
        [void]$errorList.Add([PSCustomObject]@{ 
            Type      = "Space"
            Text = "Extra Space: $extraSpaceCount extra space(s) detected"
            Index     = $match.Index
            Length    = $match.Length
            StrokePen = 5
            WordPen   = 1  
            DisplayErrorCount = 5
        })
    }
    return @($errorList.ToArray())
}

# Text Engine 2: Dictionary Mode (Spellchecks text and validates grammar/punctuation natively)
function Run-StandaloneEngine {
    param([string]$TextData)
    
    $errorList = New-Object System.Collections.ArrayList
    $wordMatches = [regex]::Matches($TextData, "\S+")
    $wordCache = @{}
    $suggestionCache = @{}

    # Uses Microsoft Word COM Object if selected
    if ($script:DictEngineType -eq "MSWord") {
        $globalDocObj = $null
        try {
            $globalWordObj = New-Object -ComObject Word.Application
            $globalWordObj.Visible = $false
            $globalDocObj = $globalWordObj.Documents.Add()
        } catch {
            [void]$errorList.Add([PSCustomObject]@{ 
                Type = "System"; Text = "System Error: Microsoft Word Core Automation failed to initialize."; StrokePen = 0; WordPen = 0; DisplayErrorCount = 0; Index = $null; Length = $null
            })
            return @($errorList.ToArray())
        }

        foreach ($match in $wordMatches) {
            [System.Windows.Forms.Application]::DoEvents()
            $rawWord = $match.Value
            
            # Skip emails and URLs
            if (($rawWord -match "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}") -or ($rawWord -match "^(www\.|https?://)")) { continue }
            
            $word = $rawWord -replace "^[^a-zA-Z0-9]+", "" -replace "[^a-zA-Z0-9]+$", ""
            $word = $word.TrimEnd('.')
            $cleanWord = $word.ToLower()
            if ($cleanWord.Length -eq 0) { continue }

            # Flag lowercase "i"
            if ($word -ceq "i") {
                [void]$errorList.Add([PSCustomObject]@{ 
                    Type = "Grammar"; Text = "Grammar Error: Lowercase 'i' used instead of 'I'"; StrokePen = 5; WordPen = 1; DisplayErrorCount = 5; Index = $match.Index; Length = $match.Length
                })
                continue 
            }

            # Check spelling
            if (-not $wordCache.ContainsKey($cleanWord)) {
                try {
                    $isError = -not $globalWordObj.CheckSpelling($word)
                    $wordCache[$cleanWord] = $isError
                    if ($isError) {
                        $suggestions = $globalWordObj.GetSpellingSuggestions($word)
                        if ($null -ne $suggestions -and $suggestions.Count -gt 0) {
                            foreach ($sug in $suggestions) { $suggestionCache[$cleanWord] = $sug.Name; break }
                        } else { $suggestionCache[$cleanWord] = "" }
                    }
                } catch { $wordCache[$cleanWord] = $true; $suggestionCache[$cleanWord] = "" }
            }

            if ($wordCache[$cleanWord]) {
                $displaySugg = if ($suggestionCache.ContainsKey($cleanWord) -and $suggestionCache[$cleanWord] -ne "") { " (Expected: '$($suggestionCache[$cleanWord])')" } else { "" }
                [void]$errorList.Add([PSCustomObject]@{ 
                    Type = "Typo"; Text = "Typo: '$rawWord'$displaySugg"; StrokePen = 5; WordPen = 1; DisplayErrorCount = 5; Index = $match.Index; Length = $match.Length
                })
            }
        }
        
        # Cleanup MS Word Objects
        try {
			if ($null -ne $globalDocObj) { $globalDocObj.Close([ref]0); [System.Runtime.InteropServices.Marshal]::ReleaseComObject($globalDocObj) | Out-Null }
			$globalWordObj.Quit()
		} catch {}
		[void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($globalWordObj)
		[GC]::Collect(); [GC]::WaitForPendingFinalizers()
    
    } else {
        # Uses built-in Windows WPF Spellcheck API
        try {
            $wpfBox = New-Object System.Windows.Controls.TextBox
            $wpfBox.SpellCheck.IsEnabled = $true
            $pumpWpf = {
                $frame = New-Object System.Windows.Threading.DispatcherFrame
                [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [System.Action]{ $frame.Continue = $false }) | Out-Null
                [System.Windows.Threading.Dispatcher]::PushFrame($frame)
            }
            
            # Autodetect system language for spellcheck
            $systemLang = [System.Globalization.CultureInfo]::CurrentCulture.IetfLanguageTag
            $testLangs = @($systemLang, "en-US", "en-IN", "en-GB", "en-AU", "en-CA") | Select-Object -Unique
            $activeLang = $null
            foreach ($langTag in $testLangs) {
                try {
                    $wpfBox.Language = [System.Windows.Markup.XmlLanguage]::GetLanguage($langTag)
                    $wpfBox.Text = "zzxxqqk" 
                    $attempts = 0
                    while ($null -eq $wpfBox.GetSpellingError(0) -and $attempts -lt 15) { & $pumpWpf; Start-Sleep -Milliseconds 10; $attempts++ }
                    if ($null -ne $wpfBox.GetSpellingError(0)) { $activeLang = $langTag; break }
                } catch {}
            }
            
            if ($null -eq $activeLang) {
                [void]$errorList.Add([PSCustomObject]@{ 
                    Type = "System"; Text = "System Warning: Windows typing dictionary package is missing."; StrokePen = 0; WordPen = 0; DisplayErrorCount = 0; Index = $null; Length = $null
                })
            }
            
            foreach ($match in $wordMatches) {
                [System.Windows.Forms.Application]::DoEvents()
                $rawWord = $match.Value
                if (($rawWord -match "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}") -or ($rawWord -match "^(www\.|https?://)")) { continue }
                $word = $rawWord -replace "^[^a-zA-Z0-9]+", "" -replace "[^a-zA-Z0-9]+$", ""
                $word = $word.TrimEnd('.')
                $cleanWord = $word.ToLower()
                if ($cleanWord.Length -eq 0) { continue }
				
                if ($word -ceq "i") {
                    [void]$errorList.Add([PSCustomObject]@{ 
                        Type = "Grammar"; Text = "Typo: 'i' (Expected: 'I')"; StrokePen = 5; WordPen = 1; DisplayErrorCount = 5; Index = $match.Index; Length = $match.Length
                    })
                    continue 
                }

                if (-not $wordCache.ContainsKey($cleanWord)) {
                    $wpfBox.Text = $word
                    & $pumpWpf; Start-Sleep -Milliseconds 5; & $pumpWpf
                    $spellingError = $wpfBox.GetSpellingError(0)
                    $isError = ($null -ne $spellingError)
                    $wordCache[$cleanWord] = $isError
                    if ($isError -and $spellingError.Suggestions) {
                        $firstSugg = $spellingError.Suggestions | Select-Object -First 1
                        if ($firstSugg) { $suggestionCache[$cleanWord] = $firstSugg }
                    } else { $suggestionCache[$cleanWord] = "" }
                }

                if ($wordCache[$cleanWord]) {
                    $displaySugg = if ($suggestionCache.ContainsKey($cleanWord) -and $suggestionCache[$cleanWord] -ne "") { " (Expected: '$($suggestionCache[$cleanWord])')" } else { "" }
                    [void]$errorList.Add([PSCustomObject]@{ 
                        Type = "Typo"; Text = "Typo: '$rawWord'$displaySugg"; StrokePen = 5; WordPen = 1; DisplayErrorCount = 5; Index = $match.Index; Length = $match.Length
                    })
                }
            }
        } catch {
            [void]$errorList.Add([PSCustomObject]@{ 
                Type = "System"; Text = "System Warning: Native SpellCheck configuration failed."; StrokePen = 0; WordPen = 0; DisplayErrorCount = 0; Index = $null; Length = $null
            })
        }
    }

    # Catch general grammatical formatting errors (Spaces, Punctuation gaps, Capitalization)
    foreach ($match in [regex]::Matches($TextData, " {2,}")) { 
        [void]$errorList.Add([PSCustomObject]@{ 
            Type      = "Space"; Text = "Extra or incorrect spacing detected"; Index = $match.Index; Length = $match.Length; StrokePen = 5; WordPen = 1; DisplayErrorCount = 5
        })
    }

    foreach ($match in [regex]::Matches($TextData, "([^\s.,!?;/:]+)\s+([.,!?;/:]+)")) { 
        $startIdx = $match.Index; $endIdx = $match.Index + $match.Length; $fullLength = $endIdx - $startIdx
        $itemsToRemove = New-Object System.Collections.ArrayList
        foreach ($err in $errorList) {
            if ($err.Index -lt $endIdx -and ($err.Index + $err.Length) -gt $startIdx) {
                if ($err.Type -eq "Typo" -or $err.Type -eq "Grammar" -or $err.Type -eq "Space") { [void]$itemsToRemove.Add($err) }
            }
        }
        foreach ($item in $itemsToRemove) { $errorList.Remove($item) }
        [void]$errorList.Add([PSCustomObject]@{ 
            Type = "PunctuationGap"; Text = "Invalid space before punctuation: '$($match.Value)'"; StrokePen = 5; WordPen = 1; DisplayErrorCount = 5; Index = $startIdx; Length = $fullLength
        })
    }

    foreach ($match in [regex]::Matches($TextData, "([.,!?;/:]+)([a-zA-Z0-9]+)")) {
        $punc = $match.Groups[1].Value; $targetWord = $match.Groups[2].Value; $startIdx = $match.Index
        while ($startIdx -gt 0 -and -not [char]::IsWhiteSpace($TextData[$startIdx - 1])) { $startIdx-- }
        $endIdx = $match.Index + $match.Length
        while ($endIdx -lt $TextData.Length -and -not [char]::IsWhiteSpace($TextData[$endIdx])) { $endIdx++ }
        $fullLength = $endIdx - $startIdx; $fullWord = $TextData.Substring($startIdx, $fullLength); $isException = $false

        if ($match.Index -gt 0) {
            $prevChar = $TextData.Substring($match.Index - 1, 1)
            if ($prevChar -match "[0-9]" -and $targetWord -match "^[0-9]+$" -and $punc -match "^[.,:]$") { $isException = $true }
        }
        if ($fullWord -match "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}") { $isException = $true }
        if ($fullWord -match "^(www\.|https?://)") { $isException = $true }
        
        if (-not $isException) {
            $itemsToRemove = New-Object System.Collections.ArrayList
            foreach ($err in $errorList) {
                if ($err.Index -lt $endIdx -and ($err.Index + $err.Length) -gt $startIdx) {
                    if ($err.Type -eq "Typo" -or $err.Type -eq "Grammar") { [void]$itemsToRemove.Add($err) }
                }
            }
            foreach ($item in $itemsToRemove) { $errorList.Remove($item) }
            [void]$errorList.Add([PSCustomObject]@{ 
                Type = "PunctuationGap"; Text = "Missing space after punctuation: '$fullWord'"; StrokePen = 5; WordPen = 1; DisplayErrorCount = 5; Index = $startIdx; Length = $fullLength
            })
        }
    }

    foreach ($match in [regex]::Matches($TextData, "([.]\s+)([a-z][a-zA-Z0-9'-]*)")) {
        $targetWord = $match.Groups[2].Value; $wordIdx = $match.Groups[2].Index; $wordLen = $match.Groups[2].Length
        $itemsToRemove = New-Object System.Collections.ArrayList
        foreach ($err in $errorList) {
            if ($err.Index -ge $wordIdx -and ($err.Index + $err.Length) -le ($wordIdx + $wordLen)) {
                if ($err.Type -eq "Typo" -or $err.Type -eq "Grammar") { [void]$itemsToRemove.Add($err) }
            }
        }
        foreach ($item in $itemsToRemove) { $errorList.Remove($item) }
        [void]$errorList.Add([PSCustomObject]@{ 
            Type = "Capitalization"; Text = "Capitalization Error: '$targetWord' should be capitalized after period."; StrokePen = 5; WordPen = 1; DisplayErrorCount = 5; Index = $wordIdx; Length = $wordLen
        })
    }
	
    foreach ($regexMatch in [regex]::Matches($TextData, "([0-9]+\s*\.\s*[0-9]+)")) {
        if ($regexMatch.Value -match "\s") {
            $startIdx = [int]$regexMatch.Index; $fullLength = [int]$regexMatch.Length
            $itemsToRemove = New-Object System.Collections.ArrayList
            foreach ($err in $errorList) {
                if ($null -ne $err.Index -and $null -ne $err.Length) {
                    if ([int]$err.Index -lt ($startIdx + $fullLength) -and ([int]$err.Index + [int]$err.Length) -gt $startIdx) { [void]$itemsToRemove.Add($err) }
                }
            }
            foreach ($item in $itemsToRemove) { $errorList.Remove($item) }
            [void]$errorList.Add([PSCustomObject]@{ 
                Type = "NumberFormat"; Text = "Invalid space inside decimal number: '$($regexMatch.Value)'"; StrokePen = 5; WordPen = 1; DisplayErrorCount = 5; Index = $startIdx; Length = $fullLength
            })
        }
    }
    return @($errorList.ToArray()) 
}

# Text Engine 3: Anti-Spam Filter (Identifies gibberish typing to prevent score cheating)
function Invoke-AntiSpamFilter {
    param([string]$InputText, [array]$EngineErrors)
    
    $spamStrokes = 0
    $spamList = New-Object System.Collections.ArrayList
    $filteredErrors = New-Object System.Collections.ArrayList
    
    # Catch massive strings without spaces
    $possibleSpamMatches = [regex]::Matches($InputText, "\S{19,}")
    $actualSpamMatches = New-Object System.Collections.ArrayList

    foreach ($match in $possibleSpamMatches) {
        if ($val -match "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$") { continue }
        if ($val -match "-") { continue }
        [void]$actualSpamMatches.Add($match)
    }
    
    foreach ($match in $actualSpamMatches) {
        $spamStrokes += $match.Length
        $preview = if ($match.Length -gt 15) { $match.Value.Substring(0,12) + "..." } else { $match.Value }
        [void]$spamList.Add([PSCustomObject]@{
            Type = "Spam"
            Text = "Invalid Data (Ignored): Malicious key spam detected ('$preview')"
            StrokePen = 0 
            WordPen = 0
            DisplayErrorCount = $match.Length
            Index = $match.Index
            Length = $match.Length
        })
    }

    # Evaluate existing errors for gibberish characteristics
    foreach ($err in $EngineErrors) {
        $isOverlap = $false
        foreach ($match in $actualSpamMatches) {
            if ($null -ne $err.Index -and $err.Index -ge $match.Index -and $err.Index -lt ($match.Index + $match.Length)) {
                $isOverlap = $true; break
            }
        }
        if ($isOverlap) { continue }

        if ($err.Type -eq "Typo" -or $err.Type -eq "Mismatch" -or $err.Type -eq "Insertion") {
            $extractedWord = ""
            if ($err.Text -match "'([^']+)'") { $extractedWord = $matches[1] }
            
            $lower = $extractedWord.ToLower()
            $len = $lower.Length

            if ($len -ge 4) {
                $expectedWord = ""
                if ($err.Text -match "\(Expected: '([^']+)'\)") { $expectedWord = $matches[1] }
                
                $vowels = [regex]::Matches($lower, "[aeiouy]").Count
                $homeRow = [regex]::Matches($lower, "[asdfghjkl]").Count
                $topRow  = [regex]::Matches($lower, "[qwertyuiop]").Count
                $botRow  = [regex]::Matches($lower, "[zxcvbnm]").Count
                $maxRow  = [math]::Max($homeRow, [math]::Max($topRow, $botRow))

                $isGibberish = $false
                
                # Identify impossible words based on length and vowel counts
                if ($expectedWord -ne "") {
                    if ([math]::Abs($len - $expectedWord.Length) -ge 3) { $isGibberish = $true }
                } else {
                    if ($len -ge 8 -and $vowels -eq 0) { $isGibberish = $true }
                    if ($len -ge 10 -and $vowels -le 1) { $isGibberish = $true }
                    if ($lower -match "[bcdfghjklmnpqrstvwxz]{5,}") { $isGibberish = $true }
                }

                # High consonant count or repeating characters
                if ($lower -match "[bcdfghjklmnpqrstvwxz]{6,}") { $isGibberish = $true }
                if (($maxRow / $len) -ge 0.75 -and $vowels -le 1) { $isGibberish = $true }
                if ($lower -match "(.)\1{3,}") { $isGibberish = $true }

                if ($isGibberish) {
                    $rawPenalty = $len + 5
                    $err.Type = "Gibberish"
                    $err.Text = "Gibberish: '$extractedWord' ($rawPenalty Stroke Penalty)"
                    $err.StrokePen = $rawPenalty
                    $err.WordPen = [math]::Ceiling($rawPenalty / 5.0)
                    $err.DisplayErrorCount = $len
                } else {
                    $err.DisplayErrorCount = 5
                }
            } else {
                $err.DisplayErrorCount = 5
            }
        } elseif ($err.Type -eq "Omission" -or $err.Type -eq "Space" -or $err.Type -eq "PunctuationGap" -or $err.Type -eq "Capitalization" -or $err.Type -eq "NumberFormat" -or $err.Type -eq "Grammar") {
            if ($null -eq $err.DisplayErrorCount) { $err.DisplayErrorCount = $err.StrokePen }
        }

        [void]$filteredErrors.Add($err)
    }

    return @{
        SpamStrokes = $spamStrokes
        FinalErrors = (@($filteredErrors.ToArray()) + @($spamList.ToArray()))
    }
}

# =======================================================================================
# UI Elements Setup
# =======================================================================================

# 1. Main Form Initialization
$form = New-Object System.Windows.Forms.Form
$form.Text = "DSSSB Typist"
$form.Size = New-Object System.Drawing.Size(900, 1020)
$form.MinimumSize = New-Object System.Drawing.Size(700, 850)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#E2E8F0")
$form.Add_FormClosing($form_FormClosing)

$lblHeader = New-Object System.Windows.Forms.Label
$lblHeader.Text = "DSSSB Evaluation Engine"
$lblHeader.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 18)
$lblHeader.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#0F172A")
$lblHeader.Size = New-Object System.Drawing.Size(2000, 40) 
$lblHeader.Location = New-Object System.Drawing.Point(30, 20)
$form.Controls.Add($lblHeader)

$lblSubHeader = New-Object System.Windows.Forms.Label
$lblSubHeader.Text = "Exam Profile: DSSSB LDC Standard"
$lblSubHeader.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblSubHeader.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#475569")
$lblSubHeader.Size = New-Object System.Drawing.Size(2000, 20)
$lblSubHeader.Location = New-Object System.Drawing.Point(34, 60)
$form.Controls.Add($lblSubHeader)

$lblAuthor = New-Object System.Windows.Forms.Label
$lblAuthor.Text = "Author: Verma_Ji"
$lblAuthor.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$lblAuthor.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#005FB8") 
$lblAuthor.Size = New-Object System.Drawing.Size(2000, 25)
$lblAuthor.Location = New-Object System.Drawing.Point(34, 80)
$lblAuthor.Cursor = [System.Windows.Forms.Cursors]::Hand
$lblAuthor.Add_Click({
    try { [System.Diagnostics.Process]::Start("https://t.me/vermaJiofficial") } catch { [System.Windows.Forms.MessageBox]::Show("Unable to open browser link.", "Navigation Error") }
})
$form.Controls.Add($lblAuthor)

$CardPaintLayout = { param($sender, $e) Invoke-PaintRoundedCorners $sender $e 14 "#CBD5E1" "#FFFFFF" }

# 2. Settings Configuration Panel
$pnlConfig = New-Object System.Windows.Forms.Panel
$pnlConfig.Location = New-Object System.Drawing.Point(30, 115) 
$pnlConfig.Height = 100 
$pnlConfig.Width = 840
$pnlConfig.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$pnlConfig.Add_Paint($CardPaintLayout)
$form.Controls.Add($pnlConfig)

$lblFile = New-Object System.Windows.Forms.Label
$lblFile.Text = "Target File"
$lblFile.Location = New-Object System.Drawing.Point(20, 25)
$lblFile.Size = New-Object System.Drawing.Size(100, 20)
$lblFile.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$lblFile.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#334155")
$lblFile.BackColor = [System.Drawing.Color]::White
$pnlConfig.Controls.Add($lblFile)

$txtPath = New-Object System.Windows.Forms.TextBox
$txtPath.Location = New-Object System.Drawing.Point(125, 22)
$txtPath.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$txtPath.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#FFFFFF")
$pnlConfig.Controls.Add($txtPath)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = "Browse"
$btnBrowse.Location = New-Object System.Drawing.Point(650, 20)
$btnBrowse.Width = 80
$btnBrowse.Height = 25
$btnBrowse.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnBrowse.FlatAppearance.BorderSize = 0
$btnBrowse.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::Transparent
$btnBrowse.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::Transparent
$btnBrowse.BackColor = [System.Drawing.Color]::Transparent
$btnBrowse.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnBrowse.Tag = "normal"
$btnBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = "Text Files (*.txt)|*.txt|All Files (*.*)|*.*"
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtPath.Text = $dialog.FileName }
})
$btnBrowse.Add_MouseEnter({ $this.Tag = "hover"; $this.Invalidate() })
$btnBrowse.Add_MouseLeave({ $this.Tag = "normal"; $this.Invalidate() })
$btnBrowse.Add_Paint({
    param($sender, $e)
    $fill = if ($sender.Tag -eq "hover") { "#EBEBEB" } else { "#F1F5F9" }
    Invoke-PaintRoundedCorners $sender $e 10 "#CBD5E1" $fill
    $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $sender.Text, $sender.Font, $sender.ClientRectangle, [System.Drawing.ColorTranslator]::FromHtml("#334155"), $flags)
})
$pnlConfig.Controls.Add($btnBrowse)

$btnToggleEngine = New-Object System.Windows.Forms.Button
$btnToggleEngine.Text = "Engine: Native"
$btnToggleEngine.Width = 140
$btnToggleEngine.Height = 25
$btnToggleEngine.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnToggleEngine.FlatAppearance.BorderSize = 0
$btnToggleEngine.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::Transparent
$btnToggleEngine.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::Transparent
$btnToggleEngine.BackColor = [System.Drawing.Color]::Transparent
$btnToggleEngine.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnToggleEngine.Tag = "normal"
$btnToggleEngine.Add_Click({
    if ($script:IsTestRunning) { return }
    if ($script:DictEngineType -eq "Native") {
        $wordInstalled = $false
        try {
            $testWord = New-Object -ComObject Word.Application -ErrorAction Stop
            if ($testWord) { $wordInstalled = $true; $testWord.Quit(); [System.Runtime.InteropServices.Marshal]::ReleaseComObject($testWord) | Out-Null }
        } catch { $wordInstalled = $false }
        if (-not $wordInstalled) {
            [System.Windows.Forms.MessageBox]::Show("Microsoft Word is not installed or registered on this system. Cannot switch to MS Word Engine.", "MS Word Not Installed", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        $script:DictEngineType = "MSWord"
        $btnToggleEngine.Text = "Engine: MS Word"
    } else {
        $script:DictEngineType = "Native"
        $btnToggleEngine.Text = "Engine: Native"
    }
    $btnToggleEngine.Invalidate()
})
$btnToggleEngine.Add_MouseEnter({ $this.Tag = "hover"; $this.Invalidate() })
$btnToggleEngine.Add_MouseLeave({ $this.Tag = "normal"; $this.Invalidate() })
$btnToggleEngine.Add_Paint({
    param($sender, $e)
    $fill = if ($sender.Tag -eq "hover") { "#EBEBEB" } else { "#F1F5F9" }
    Invoke-PaintRoundedCorners $sender $e 10 "#CBD5E1" $fill
    $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter
    $color = if ($script:IsTestRunning) { "#94A3B8" } else { "#005FB8" }
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $sender.Text, $sender.Font, $sender.ClientRectangle, [System.Drawing.ColorTranslator]::FromHtml($color), $flags)
})
$pnlConfig.Controls.Add($btnToggleEngine)

$lblTime = New-Object System.Windows.Forms.Label
$lblTime.Text = "Duration (Mins)"
$lblTime.Location = New-Object System.Drawing.Point(20, 65)
$lblTime.Size = New-Object System.Drawing.Size(115, 20)
$lblTime.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$lblTime.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#334155")
$lblTime.BackColor = [System.Drawing.Color]::White
$pnlConfig.Controls.Add($lblTime)

$txtTime = New-Object System.Windows.Forms.TextBox
$txtTime.Text = "10"
$txtTime.Location = New-Object System.Drawing.Point(135, 62) 
$txtTime.Width = 60
$txtTime.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$pnlConfig.Controls.Add($txtTime)

$btnToggleMode = New-Object System.Windows.Forms.Button
$btnToggleMode.Text = "Mode: Dictionary"
$btnToggleMode.Location = New-Object System.Drawing.Point(210, 60)
$btnToggleMode.Width = 140
$btnToggleMode.Height = 25
$btnToggleMode.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnToggleMode.FlatAppearance.BorderSize = 0
$btnToggleMode.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::Transparent
$btnToggleMode.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::Transparent
$btnToggleMode.BackColor = [System.Drawing.Color]::Transparent
$btnToggleMode.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnToggleMode.Tag = "normal"
$btnToggleMode.Add_Click({
    if ($script:IsTestRunning) { return }
    if ($script:AppMode -eq "Dictionary") {
        $script:AppMode = "Comparison"
        $btnToggleMode.Text = "Mode: Comparison"
        $lblMaster.Text = "Paste Typed Text Here (Required for Comparison Mode)"
        $lblFile.Text = "Master File"
        $script:balloonTip.SetToolTip($btnBrowse, "Browse and load a .txt master file containing the original reference paragraph.")
    } else {
        $script:AppMode = "Dictionary"
        $btnToggleMode.Text = "Mode: Dictionary"
        $lblMaster.Text = "Paste Typed Text Here (Leave blank to read from Target File)"
        $lblFile.Text = "Target File"
        $script:balloonTip.SetToolTip($btnBrowse, "Browse and load a .txt target file containing your typed draft.")
    }
    $btnToggleMode.Invalidate()
})
$btnToggleMode.Add_MouseEnter({ $this.Tag = "hover"; $this.Invalidate() })
$btnToggleMode.Add_MouseLeave({ $this.Tag = "normal"; $this.Invalidate() })
$btnToggleMode.Add_Paint({
    param($sender, $e)
    $fill = if ($sender.Tag -eq "hover") { "#EBEBEB" } else { "#F1F5F9" }
    Invoke-PaintRoundedCorners $sender $e 10 "#CBD5E1" $fill
    $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter
    $color = if ($script:IsTestRunning) { "#94A3B8" } else { "#005FB8" }
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $sender.Text, $sender.Font, $sender.ClientRectangle, [System.Drawing.ColorTranslator]::FromHtml($color), $flags)
})
$pnlConfig.Controls.Add($btnToggleMode)

$btnToggleUnit = New-Object System.Windows.Forms.Button
$btnToggleUnit.Text = "Data: Words"
$btnToggleUnit.Location = New-Object System.Drawing.Point(360, 60)
$btnToggleUnit.Width = 110
$btnToggleUnit.Height = 25
$btnToggleUnit.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnToggleUnit.FlatAppearance.BorderSize = 0
$btnToggleUnit.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::Transparent
$btnToggleUnit.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::Transparent
$btnToggleUnit.BackColor = [System.Drawing.Color]::Transparent
$btnToggleUnit.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnToggleUnit.Tag = "normal"
$btnToggleUnit.Add_MouseEnter({ $this.Tag = "hover"; $this.Invalidate() })
$btnToggleUnit.Add_MouseLeave({ $this.Tag = "normal"; $this.Invalidate() })
$btnToggleUnit.Add_Paint({
    param($sender, $e)
    $fill = if ($sender.Tag -eq "hover") { "#EBEBEB" } else { "#F1F5F9" }
    Invoke-PaintRoundedCorners $sender $e 10 "#CBD5E1" $fill
    $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter
    $color = if ($script:IsTestRunning) { "#94A3B8" } else { "#005FB8" }
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $sender.Text, $sender.Font, $sender.ClientRectangle, [System.Drawing.ColorTranslator]::FromHtml($color), $flags)
})
$pnlConfig.Controls.Add($btnToggleUnit)

$btnIgnore = New-Object System.Windows.Forms.Button
$btnIgnore.Text = "Ignore Errors"
$btnIgnore.Location = New-Object System.Drawing.Point(480, 60)
$btnIgnore.Width = 110
$btnIgnore.Height = 25
$btnIgnore.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnIgnore.FlatAppearance.BorderSize = 0
$btnIgnore.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::Transparent
$btnIgnore.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::Transparent
$btnIgnore.BackColor = [System.Drawing.Color]::Transparent
$btnIgnore.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnIgnore.Tag = "normal"
$btnIgnore.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#DC2626") 
$btnIgnore.Add_MouseEnter({ $this.Tag = "hover"; $this.Invalidate() })
$btnIgnore.Add_MouseLeave({ $this.Tag = "normal"; $this.Invalidate() })
$btnIgnore.Add_Paint({
    param($sender, $e)
    $fill = if ($sender.Tag -eq "hover") { "#FEE2E2" } else { "#FEF2F2" } 
    Invoke-PaintRoundedCorners $sender $e 10 "#FCA5A5" $fill
    $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter
    $color = if ($script:IsTestRunning) { [System.Drawing.ColorTranslator]::FromHtml("#94A3B8") } else { $sender.ForeColor }
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $sender.Text, $sender.Font, $sender.ClientRectangle, $color, $flags)
})
$pnlConfig.Controls.Add($btnIgnore)

$btnFreeHand = New-Object System.Windows.Forms.Button
$btnFreeHand.Text = "Free Hand Typing"
$btnFreeHand.Location = New-Object System.Drawing.Point(600, 60)
$btnFreeHand.Width = 130
$btnFreeHand.Height = 25
$btnFreeHand.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnFreeHand.FlatAppearance.BorderSize = 0
$btnFreeHand.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::Transparent
$btnFreeHand.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::Transparent
$btnFreeHand.BackColor = [System.Drawing.Color]::Transparent
$btnFreeHand.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnFreeHand.Tag = "normal"
$btnFreeHand.Add_MouseEnter({ $this.Tag = "hover"; $this.Invalidate() })
$btnFreeHand.Add_MouseLeave({ $this.Tag = "normal"; $this.Invalidate() })
$btnFreeHand.Add_Paint({
    param($sender, $e)
    $fill = if ($script:IsFreeHandActive) { "#DCFCE7" } elseif ($sender.Tag -eq "hover") { "#EBEBEB" } else { "#F1F5F9" }
    $border = if ($script:IsFreeHandActive) { "#22C55E" } else { "#CBD5E1" }
    $textCol = if ($script:IsFreeHandActive) { "#15803D" } else { "#1E293B" }
    Invoke-PaintRoundedCorners $sender $e 10 $border $fill
    $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $sender.Text, $sender.Font, $sender.ClientRectangle, [System.Drawing.ColorTranslator]::FromHtml($textCol), $flags)
})
$pnlConfig.Controls.Add($btnFreeHand)

$btnDistraction = New-Object System.Windows.Forms.Button
$btnDistraction.Text = [char]::ConvertFromUtf32(0x1F507) 
$btnDistraction.Font = New-Object System.Drawing.Font("Segoe UI Emoji", 12) 
$btnDistraction.Location = New-Object System.Drawing.Point(740, 55) 
$btnDistraction.Width = 35  
$btnDistraction.Height = 35
$btnDistraction.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnDistraction.FlatAppearance.BorderSize = 0
$btnDistraction.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::Transparent
$btnDistraction.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::Transparent
$btnDistraction.BackColor = [System.Drawing.Color]::Transparent
$btnDistraction.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnDistraction.Tag = "normal"
$btnDistraction.Add_Click({
    $script:IsDistractionPlaying = -not $script:IsDistractionPlaying
    if ($script:IsDistractionPlaying) {
        if ($null -ne $script:NoisePlayer) { $script:NoisePlayer.controls.play() }
        $btnDistraction.Text = [char]::ConvertFromUtf32(0x1F50A) 
    } else {
        if ($null -ne $script:NoisePlayer) { $script:NoisePlayer.controls.stop() }
        $script:TypingStopTimer.Stop()
        $script:IsTypingLoopPlaying = $false
        try { $script:SystemSoundPlayer.Stop() } catch {}
        $btnDistraction.Text = [char]::ConvertFromUtf32(0x1F507) 
    }
    $btnDistraction.Invalidate()
})
$btnDistraction.Add_MouseEnter({ $this.Tag = "hover"; $this.Invalidate() })
$btnDistraction.Add_MouseLeave({ $this.Tag = "normal"; $this.Invalidate() })
$btnDistraction.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $fill = if ($script:IsDistractionPlaying) { "#FEE2E2" } elseif ($sender.Tag -eq "hover") { "#EBEBEB" } else { "#F1F5F9" }
    $border = if ($script:IsDistractionPlaying) { "#EF4444" } else { "#CBD5E1" }
    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml($fill))
    $pen = New-Object System.Drawing.Pen([System.Drawing.ColorTranslator]::FromHtml($border), 1)
    $rect = New-Object System.Drawing.Rectangle(0, 0, ($sender.Width - 1), ($sender.Height - 1))
    $g.FillEllipse($brush, $rect)
    $g.DrawEllipse($pen, $rect)
    $brush.Dispose(); $pen.Dispose()
    $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter
    [System.Windows.Forms.TextRenderer]::DrawText($g, $sender.Text, $sender.Font, $sender.ClientRectangle, [System.Drawing.ColorTranslator]::FromHtml("#1E293B"), $flags)
})
$pnlConfig.Controls.Add($btnDistraction)

# 3. Text Input Workspace Area
$pnlMaster = New-Object System.Windows.Forms.Panel
$pnlMaster.Location = New-Object System.Drawing.Point(30, 245)
$pnlMaster.Size = New-Object System.Drawing.Size(790, 230)
$pnlMaster.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$pnlMaster.Add_Paint($CardPaintLayout)
$form.Controls.Add($pnlMaster)

$lblMaster = New-Object System.Windows.Forms.Label
$lblMaster.Text = "Paste Typed Text Here (Leave blank to read from Target File)"
$lblMaster.Location = New-Object System.Drawing.Point(20, 15)
$lblMaster.Size = New-Object System.Drawing.Size(600, 20)
$lblMaster.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblMaster.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#64748B")
$lblMaster.BackColor = [System.Drawing.Color]::White
$pnlMaster.Controls.Add($lblMaster)

$btnCopyMaster = New-Object System.Windows.Forms.Button
$btnCopyMaster.Text = "📄"
$btnCopyMaster.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnCopyMaster.FlatAppearance.BorderSize = 0
$btnCopyMaster.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::Transparent
$btnCopyMaster.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::Transparent
$btnCopyMaster.BackColor = [System.Drawing.Color]::Transparent
$btnCopyMaster.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnCopyMaster.Font = New-Object System.Drawing.Font("Segoe UI Emoji", 10)
$btnCopyMaster.Tag = "normal"
$btnCopyMaster.Add_MouseEnter({ $this.Tag = "hover"; $this.Invalidate() })
$btnCopyMaster.Add_MouseLeave({ $this.Tag = "normal"; $this.Invalidate() })
$btnCopyMaster.Add_Paint({
    param($sender, $e)
    $fill = if ($sender.Tag -eq "hover") { "#E2E8F0" } else { "#F1F5F9" }
    Invoke-PaintRoundedCorners $sender $e 8 "#CBD5E1" $fill
    $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $sender.Text, $sender.Font, $sender.ClientRectangle, [System.Drawing.ColorTranslator]::FromHtml("#005FB8"), $flags)
})
$btnCopyMaster.Add_Click({
    try { if (![string]::IsNullOrWhiteSpace($txtMaster.Text)) { [System.Windows.Forms.Clipboard]::SetText($txtMaster.Text) } } catch {}
})
$pnlMaster.Controls.Add($btnCopyMaster)

$btnPasteMaster = New-Object System.Windows.Forms.Button
$btnPasteMaster.Text = "📋"
$btnPasteMaster.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnPasteMaster.FlatAppearance.BorderSize = 0
$btnPasteMaster.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::Transparent
$btnPasteMaster.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::Transparent
$btnPasteMaster.BackColor = [System.Drawing.Color]::Transparent
$btnPasteMaster.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnPasteMaster.Font = New-Object System.Drawing.Font("Segoe UI Emoji", 10)
$btnPasteMaster.Tag = "normal"
$btnPasteMaster.Add_MouseEnter({ $this.Tag = "hover"; $this.Invalidate() })
$btnPasteMaster.Add_MouseLeave({ $this.Tag = "normal"; $this.Invalidate() })
$btnPasteMaster.Add_Paint({
    param($sender, $e)
    $fill = if ($sender.Tag -eq "hover") { "#E2E8F0" } else { "#F1F5F9" }
    Invoke-PaintRoundedCorners $sender $e 8 "#CBD5E1" $fill
    $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $sender.Text, $sender.Font, $sender.ClientRectangle, [System.Drawing.ColorTranslator]::FromHtml("#005FB8"), $flags)
})
$btnPasteMaster.Add_Click({
    if ($txtMaster.ReadOnly) { return }
    try { if ([System.Windows.Forms.Clipboard]::ContainsText()) { $txtMaster.Text = [System.Windows.Forms.Clipboard]::GetText() } } catch {
        [System.Windows.Forms.MessageBox]::Show("Clipboard is currently locked by another process. Please try again.", "Clipboard Error")
    }
})
$pnlMaster.Controls.Add($btnPasteMaster)

$btnClearMaster = New-Object System.Windows.Forms.Button
$btnClearMaster.Text = [char]::ConvertFromUtf32(0x274C)
$btnClearMaster.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnClearMaster.FlatAppearance.BorderSize = 0
$btnClearMaster.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::Transparent
$btnClearMaster.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::Transparent
$btnClearMaster.BackColor = [System.Drawing.Color]::Transparent
$btnClearMaster.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnClearMaster.Font = New-Object System.Drawing.Font("Segoe UI Emoji", 9)
$btnClearMaster.Tag = "normal"
$btnClearMaster.Add_MouseEnter({ $this.Tag = "hover"; $this.Invalidate() })
$btnClearMaster.Add_MouseLeave({ $this.Tag = "normal"; $this.Invalidate() })
$btnClearMaster.Add_Paint({
    param($sender, $e)
    $fill = if ($sender.Tag -eq "hover") { "#FEE2E2" } else { "#F1F5F9" }
    Invoke-PaintRoundedCorners $sender $e 8 "#CBD5E1" $fill
    $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $sender.Text, $sender.Font, $sender.ClientRectangle, [System.Drawing.ColorTranslator]::FromHtml("#DC2626"), $flags)
})
$btnClearMaster.Add_Click({ if ($txtMaster.ReadOnly) { return }; $txtMaster.Text = "" })
$pnlMaster.Controls.Add($btnClearMaster)

$lblLiveStats = New-Object System.Windows.Forms.Label
$lblLiveStats.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9)
$lblLiveStats.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#0F172A")
$lblLiveStats.BackColor = [System.Drawing.Color]::White
$lblLiveStats.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$lblLiveStats.Visible = $false
$pnlMaster.Controls.Add($lblLiveStats)

$lblTimerDisplay = New-Object System.Windows.Forms.Label
$lblTimerDisplay.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold) 
$lblTimerDisplay.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#DC2626") 
$lblTimerDisplay.BackColor = [System.Drawing.Color]::White
$lblTimerDisplay.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$lblTimerDisplay.Visible = $false
$pnlMaster.Controls.Add($lblTimerDisplay)

$btnSubmitTest = New-Object System.Windows.Forms.Button
$btnSubmitTest.Text = "Submit Early"
$btnSubmitTest.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnSubmitTest.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnSubmitTest.FlatAppearance.BorderSize = 0
$btnSubmitTest.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::Transparent
$btnSubmitTest.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::Transparent
$btnSubmitTest.BackColor = [System.Drawing.Color]::Transparent
$btnSubmitTest.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnSubmitTest.Tag = "normal"
$btnSubmitTest.Visible = $false
$btnSubmitTest.Add_MouseEnter({ $this.Tag = "hover"; $this.Invalidate() })
$btnSubmitTest.Add_MouseLeave({ $this.Tag = "normal"; $this.Invalidate() })
$btnSubmitTest.Add_Paint({
    param($sender, $e)
    $fill = if ($sender.Tag -eq "hover") { "#EF4444" } else { "#DC2626" } 
    Invoke-PaintRoundedCorners $sender $e 12 $null $fill
    $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $sender.Text, $sender.Font, $sender.ClientRectangle, [System.Drawing.Color]::White, $flags)
})
$pnlMaster.Controls.Add($btnSubmitTest)

$btnStartFreeHand = New-Object System.Windows.Forms.Button
$btnStartFreeHand.Text = "START TYPING TEST"
$btnStartFreeHand.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$btnStartFreeHand.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnStartFreeHand.FlatAppearance.BorderSize = 0
$btnStartFreeHand.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::Transparent
$btnStartFreeHand.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::Transparent
$btnStartFreeHand.BackColor = [System.Drawing.Color]::Transparent
$btnStartFreeHand.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnStartFreeHand.Tag = "normal"
$btnStartFreeHand.Visible = $false
$btnStartFreeHand.Add_MouseEnter({ $this.Tag = "hover"; $this.Invalidate() })
$btnStartFreeHand.Add_MouseLeave({ $this.Tag = "normal"; $this.Invalidate() })
$btnStartFreeHand.Add_Paint({
    param($sender, $e)
    $fill = if ($sender.Tag -eq "hover") { "#16A34A" } else { "#22C55E" } 
    Invoke-PaintRoundedCorners $sender $e 16 $null $fill
    $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $sender.Text, $sender.Font, $sender.ClientRectangle, [System.Drawing.Color]::White, $flags)
})
$pnlMaster.Controls.Add($btnStartFreeHand)

$txtMaster = New-Object System.Windows.Forms.RichTextBox
$txtMaster.Multiline = $true
$txtMaster.ScrollBars = "Vertical"
$txtMaster.Location = New-Object System.Drawing.Point(20, 50)
$txtMaster.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$txtMaster.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#FFFFFF")
$txtMaster.Font = New-Object System.Drawing.Font("Segoe UI", 13.5)
$txtMaster.ForeColor = [System.Drawing.Color]::Black
$txtMaster.Add_KeyDown({
    param($sender, $e)
    Invoke-StagedTypingSound
    if ($script:IsTestRunning -and $e.KeyCode -eq [System.Windows.Forms.Keys]::Back) {
        $script:BackspaceCount++
        Invoke-UpdateLiveStats
    }
})
$pnlMaster.Controls.Add($txtMaster)

# 4. Run Analysis Button Setup
$btnCalc = New-Object System.Windows.Forms.Button
$btnCalc.Text = "Run Analysis"
$btnCalc.Location = New-Object System.Drawing.Point(30, 495) 
$btnCalc.Height = 45
$btnCalc.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnCalc.FlatAppearance.BorderSize = 0
$btnCalc.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::Transparent
$btnCalc.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::Transparent
$btnCalc.BackColor = [System.Drawing.Color]::Transparent
$btnCalc.ForeColor = [System.Drawing.Color]::White
$btnCalc.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$btnCalc.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnCalc.Tag = "normal"
$btnCalc.Add_MouseEnter({ $this.Tag = "hover"; $this.Invalidate() })
$btnCalc.Add_MouseLeave({ $this.Tag = "normal"; $this.Invalidate() })
$btnCalc.Add_Paint({
    param($sender, $e)
    $fill = if ($sender.Tag -eq "hover") { "#0053A0" } else { "#005FB8" }
    Invoke-PaintRoundedCorners $sender $e 12 $null $fill
    $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $sender.Text, $sender.Font, $sender.ClientRectangle, [System.Drawing.Color]::FromName("White"), $flags)
})
$form.Controls.Add($btnCalc)

# 5. Results & Output Console Area
$pnlOutput = New-Object System.Windows.Forms.Panel
$pnlOutput.Location = New-Object System.Drawing.Point(30, 560) 
$pnlOutput.Padding = New-Object System.Windows.Forms.Padding(12) 
$pnlOutput.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$pnlOutput.Add_Paint($CardPaintLayout)
$form.Controls.Add($pnlOutput)

$txtOutput = New-Object System.Windows.Forms.RichTextBox
$txtOutput.Multiline = $true
$txtOutput.ScrollBars = "Both" 
$txtOutput.WordWrap = $false 
$txtOutput.Dock = [System.Windows.Forms.DockStyle]::Fill
$txtOutput.Font = New-Object System.Drawing.Font("Consolas", 10)
$txtOutput.ReadOnly = $true
$txtOutput.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#FFFFFF") 
$txtOutput.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#0F172A") 
$txtOutput.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$txtOutput.Text = "`r`n  [System Ready] Select a mode and click Run Analysis..."
$pnlOutput.Controls.Add($txtOutput)

# Easter Egg Control Button
$lblVersion = New-Object System.Windows.Forms.Label
$lblVersion.Text = "DoN'T cLiCk Me"
$lblVersion.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$lblVersion.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#000000") 
$lblVersion.BackColor = [System.Drawing.Color]::Transparent
$lblVersion.Size = New-Object System.Drawing.Size(130, 20)
$lblVersion.TextAlign = [System.Drawing.ContentAlignment]::BottomRight
$lblVersion.Cursor = [System.Windows.Forms.Cursors]::Hand

$lblVersion.Add_Click({
    $popupPlayer = New-Object System.Media.SoundPlayer
    $musicPath = Join-Path $env:TEMP "gta4_popup_music.wav"
    if ($script:Base64Music.Length -gt 100) {
        try {
            $musicBytes = [System.Convert]::FromBase64String($script:Base64Music)
            [IO.File]::WriteAllBytes($musicPath, $musicBytes)
            $popupPlayer.SoundLocation = $musicPath
            $popupPlayer.Load()
            $popupPlayer.PlayLooping()
        } catch {}
    }

    $popup = New-Object System.Windows.Forms.Form
    $popup.Size = New-Object System.Drawing.Size(430, 300)
    $popup.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $popup.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $popup.ControlBox = $false 
    $popup.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#111111")

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = ""
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $lblTitle.ForeColor = [System.Drawing.Color]::White
    $lblTitle.Location = New-Object System.Drawing.Point(20, 10)
    $lblTitle.Size = New-Object System.Drawing.Size(370, 20)
    $popup.Controls.Add($lblTitle)

    $picLogo = New-Object System.Windows.Forms.PictureBox
    $picLogo.Size = New-Object System.Drawing.Size(370, 110)
    $picLogo.Location = New-Object System.Drawing.Point(20, 35)
    $picLogo.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    try {
        $imgBytes = [System.Convert]::FromBase64String($script:Base64Logo)
        $ms = New-Object System.IO.MemoryStream(,$imgBytes)
        $picLogo.Image = [System.Drawing.Image]::FromStream($ms)
    } catch {}
    $popup.Controls.Add($picLogo)

    $lblMsg = New-Object System.Windows.Forms.Label
    $lblMsg.Text = """We all do dumb things. That's what makes us human."""
    $lblMsg.Font = New-Object System.Drawing.Font("Segoe UI", 11.5, [System.Drawing.FontStyle]::Italic)
    $lblMsg.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#E2E8F0") 
    $lblMsg.Location = New-Object System.Drawing.Point(20, 155)
    $lblMsg.Size = New-Object System.Drawing.Size(370, 55)
    $lblMsg.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $popup.Controls.Add($lblMsg)

    $btnOkPopup = New-Object System.Windows.Forms.Button
    $btnOkPopup.Text = "Close"
    $btnOkPopup.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $btnOkPopup.Size = New-Object System.Drawing.Size(90, 30)
    $btnOkPopup.Location = New-Object System.Drawing.Point(170, 220)
    $btnOkPopup.BackColor = [System.Drawing.Color]::White
    $btnOkPopup.ForeColor = [System.Drawing.Color]::Black
    $btnOkPopup.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnOkPopup.Add_Click({ $popup.Close() })
    $popup.Controls.Add($btnOkPopup)

    [void]$popup.ShowDialog($form)
    if ($null -ne $popupPlayer) { try { $popupPlayer.Stop() } catch {}; $popupPlayer.Dispose() }
    $popup.Dispose()
})
$form.Controls.Add($lblVersion)


# =======================================================================================
# Test Logic & Event Management
# =======================================================================================

function Invoke-HighlightTextBoxErrors {
    $txtMaster.SelectAll()
    $txtMaster.SelectionColor = [System.Drawing.Color]::Black
    $txtMaster.SelectionBackColor = [System.Drawing.Color]::White

    for ($i = 0; $i -lt $script:CurrentErrorObjects.Count; $i++) {
        $errNum = $i + 1
        if ($script:IgnoredErrorIndices -contains $errNum) { continue }
        $err = $script:CurrentErrorObjects[$i]
        if ($null -ne $err.Index -and $null -ne $err.Length -and $err.Index -ge 0 -and $err.Length -gt 0 -and ($err.Index + $err.Length) -le $txtMaster.TextLength) {
            $txtMaster.Select($err.Index, $err.Length)
            $txtMaster.SelectionColor = [System.Drawing.Color]::Red
            if ($err.Type -eq "Space" -or $err.Type -eq "Spacing" -or $err.Type -eq "NumberFormat") {
                $txtMaster.SelectionBackColor = [System.Drawing.Color]::LightPink
            }
        }
    }
    $txtMaster.Select(0, 0)
    $txtMaster.SelectionColor = [System.Drawing.Color]::Black
}

# Real-time UI Updates for Live Testing
$LiveTimer = New-Object System.Windows.Forms.Timer
$LiveTimer.Interval = 1000

function Invoke-UpdateLiveStats {
    if (-not $script:IsFreeHandActive) { return }
    $rawText = $txtMaster.Text
    $tempSpam = Invoke-AntiSpamFilter -InputText $rawText -EngineErrors @()
    $strokes = $rawText.Length - $tempSpam.SpamStrokes
    if ($strokes -lt 0) { $strokes = 0 }

    $elapsedSeconds = $script:FreeHandTotalSeconds - $script:FreeHandSecondsLeft
    if ($elapsedSeconds -le 0) { $elapsedSeconds = 1 }
    
    $liveWpm = ($strokes / 5.0) / ($elapsedSeconds / 60.0)
    $mins = [math]::Floor($script:FreeHandSecondsLeft / 60)
    $secs = $script:FreeHandSecondsLeft % 60
    
    $lblTimerDisplay.Text = "{0:D2}:{1:D2}" -f [int]$mins, [int]$secs
    $lblLiveStats.Text = "Strokes: $strokes  |  Speed: $([math]::Round($liveWpm, 1)) WPM  |  Backspaces: $($script:BackspaceCount)"
}

$txtMaster.Add_TextChanged({ if ($script:IsTestRunning) { Invoke-UpdateLiveStats } })

function Invoke-EndFreeHandTest {
    $LiveTimer.Stop()
    $txtMaster.ReadOnly = $true
    $script:IsFreeHandActive = $false; $script:IsTestRunning = $false
	$pnlConfig.Invalidate($true); $btnFreeHand.Invalidate(); $lblMaster.Visible = $true
    $btnCopyMaster.Visible = $true; $btnPasteMaster.Visible = $true; $btnClearMaster.Visible = $true
    $lblLiveStats.Visible = $false; $lblTimerDisplay.Visible = $false; $btnStartFreeHand.Visible = $false; $btnSubmitTest.Visible = $false
    
    $txtOutput.Text = "`r`n  Evaluating typing test results..."
    [System.Windows.Forms.Application]::DoEvents()

    $typedText = $txtMaster.Text
    $script:LastScale = 2.0
    
    if ($script:AppMode -eq "Comparison") {
        $rawText = Get-Content $txtPath.Text -Raw -Encoding UTF8
        $masterTextFile = if ($null -ne $rawText) { $rawText -replace "`r`n", "`n" } else { "" }
        [array]$errorsArray = Run-ComparisonEngine -TypedText $typedText -MasterText $masterTextFile
    } else {
        [array]$errorsArray = Run-StandaloneEngine -TextData $typedText
    }
    $spamResult = Invoke-AntiSpamFilter -InputText $typedText -EngineErrors $errorsArray
    
    $script:LastGrossStrokes = $typedText.Length - $spamResult.SpamStrokes
    if ($script:LastGrossStrokes -lt 0) { $script:LastGrossStrokes = 0 }
    $script:LastGrossWords = $script:LastGrossStrokes / 5.0
    
    $script:CurrentErrorObjects = $spamResult.FinalErrors
    $script:IgnoredErrorIndices = @()
    
    $actualElapsedSecs = $script:FreeHandTotalSeconds - $script:FreeHandSecondsLeft
    if ($actualElapsedSecs -le 0) { $actualElapsedSecs = 1 }
    $script:LastDuration = $actualElapsedSecs / 60.0
    $script:HasRun = $true
    
    Invoke-RenderScoreboard
    Invoke-HighlightTextBoxErrors
}

$LiveTimer.Add_Tick({
    if (-not $script:IsTestRunning) {
        $script:CountdownSeconds--
        if ($script:CountdownSeconds -gt 0) { $lblTimerDisplay.Text = "Starts in $($script:CountdownSeconds)..." } else {
            $script:IsTestRunning = $true; $pnlConfig.Invalidate($true)
            $txtMaster.ReadOnly = $false; $txtMaster.Focus(); $btnSubmitTest.Visible = $true; Invoke-UpdateLiveStats 
        }
    } else {
        if ($script:FreeHandSecondsLeft -gt 0) { $script:FreeHandSecondsLeft--; Invoke-UpdateLiveStats } else {
            $LiveTimer.Stop(); [System.Windows.Forms.MessageBox]::Show("Time is up! Processing your metrics now.", "Session Finished")
            Invoke-EndFreeHandTest
        }
    }
})

$btnSubmitTest.Add_Click({ if ($script:IsTestRunning) { [System.Windows.Forms.MessageBox]::Show("Test manually submitted early. Processing exact elapsed time metrics...", "Early Submission"); Invoke-EndFreeHandTest } })

function Invoke-BoldNetSpeedLogic {
    if ($txtOutput.TextLength -gt 0) {
        $searchText = "NET SPEED"
        $idx = $txtOutput.Text.IndexOf($searchText)
        if ($idx -ge 0) {
            $endIdx = $txtOutput.Text.IndexOf("`n", $idx)
            if ($endIdx -lt 0) { $endIdx = $txtOutput.Text.Length }
            $txtOutput.Select($idx, $endIdx - $idx)
            $txtOutput.SelectionFont = New-Object System.Drawing.Font($txtOutput.Font, [System.Drawing.FontStyle]::Bold)
            $txtOutput.Select(0, 0)
        }
    }
}

# Processes errors and renders the final scoreboard view
function Invoke-RenderScoreboard {
    if (-not $script:HasRun) { return }
    $totalDisplayErrorCounter = 0
    $activeStrokesPen = 0
    $activeWordsPen = 0
    $gibberishStrokes = 0
    $gibberishWords = 0
    $renderedLogItems = @()
    
    for ($i = 0; $i -lt $script:CurrentErrorObjects.Count; $i++) {
        $errNum = $i + 1
        $errObj = $script:CurrentErrorObjects[$i]
        
        if ($script:IgnoredErrorIndices -contains $errNum) {
            $renderedLogItems += "  - [IGNORED] [$errNum] $($errObj.Text)"
        } else {
            $activeWordsPen += $errObj.WordPen
            $activeStrokesPen += $errObj.StrokePen
            
            # Identify flat gibberish penalties
            if ($errObj.Type -eq "Gibberish") {
                $gibberishStrokes += $errObj.StrokePen
                $gibberishWords += $errObj.WordPen
            }
            
            $totalDisplayErrorCounter += $errObj.DisplayErrorCount
            $renderedLogItems += "  - [$errNum] $($errObj.Text)"
        }
    }

    $grossWords = $script:LastGrossStrokes / 5.0
    
    # Mathematical backend isolates Gibberish from the standard multiplier
    $standardWordsPen = $activeWordsPen - $gibberishWords
    $finalWordsDeductions = ($script:LastScale * $standardWordsPen) + $gibberishWords     
    $finalNetWords = $grossWords - $finalWordsDeductions

    $standardStrokesPen = $activeStrokesPen - $gibberishStrokes
    $finalStrokesDeductions = ($script:LastScale * $standardStrokesPen) + $gibberishStrokes 
    $finalNetStrokes = $script:LastGrossStrokes - $finalStrokesDeductions

    if ($script:LastGrossStrokes -gt 0) { $accuracy = ($finalNetStrokes / $script:LastGrossStrokes) * 100 } else { $accuracy = 0.0 }
    if ($accuracy -lt 0) { $accuracy = 0.0 }
    
    $grossWpm = $grossWords / $script:LastDuration
    $netWpm = $finalNetWords / $script:LastDuration
    if ($netWpm -lt 0 -and $script:LastGrossStrokes -gt 0) {
        # Allow negative net speed calculations to properly reflect heavy cheat penalties
    } elseif ($netWpm -lt 0) {
        $netWpm = 0.0
    }

    if ($script:UnitMode -eq "Words") {
        $col1 = "{0,-32}{1}" -f "  Gross Words Typed : $([math]::Round($grossWords, 2))", "Error Words     : $([math]::Round(($totalDisplayErrorCounter / 5.0), 2))"
        $col2 = "{0,-32}{1}" -f "  Deduction Ratio   : $($script:LastScale)x", "Net Compliant   : $([math]::Round($finalNetWords, 2)) Words"
    } else {
        $col1 = "{0,-32}{1}" -f "  Gross Key Strokes : $($script:LastGrossStrokes)", "Errors Detected : $totalDisplayErrorCounter"
        $col2 = "{0,-32}{1}" -f "  Deduction Ratio   : $($script:LastScale)x", "Net Compliant   : $([int][math]::Floor($finalNetStrokes)) Strokes"
    }

    $logOutput = if ($renderedLogItems.Count -gt 0) { $renderedLogItems -join "`r`n" } else { "  - No errors detected." }
    $formattedDuration = [math]::Round($script:LastDuration, 2)

    $sb = @(
        "---------------------------------------------------------------------------------------",
        "  Candidate Practice Run ID : Exam Profile (DSSSB LDC Standard)",
        "  Evaluation Script Author  : Verma_Ji",
        "  Calculated Time Frame     : $formattedDuration Minute(s)",
        "---------------------------------------------------------------------------------------",
        $col1,
        $col2,
        "---------------------------------------------------------------------------------------",
        "  TYPING ACCURACY   : $([math]::Round($accuracy, 2)) %",
        "  GROSS SPEED       : $([math]::Round($grossWpm, 2)) WPM",
        "  NET SPEED         : $([math]::Round($netWpm, 2)) WPM",
        "  BACKSPACES USED   : $($script:BackspaceCount)", 
        "---------------------------------------------------------------------------------------",
        "", "[Detailed Log]:", "[Analysis Log Output]", $logOutput, "", "", "", "" 
    )

    $txtOutput.Text = $sb -join "`r`n"
    Invoke-BoldNetSpeedLogic
    $txtOutput.SelectionStart = 0; $txtOutput.ScrollToCaret(); $txtOutput.Refresh()
}

$btnFreeHand.Add_Click({
    if ($script:IsFreeHandActive) {
        $LiveTimer.Stop(); $script:IsFreeHandActive = $false; $script:IsTestRunning = $false
		$pnlConfig.Invalidate($true); $btnFreeHand.Invalidate(); $lblMaster.Visible = $true
        $btnCopyMaster.Visible = $true; $btnPasteMaster.Visible = $true; $btnClearMaster.Visible = $true
        $lblLiveStats.Visible = $false; $lblTimerDisplay.Visible = $false; $btnStartFreeHand.Visible = $false; $btnSubmitTest.Visible = $false
        return
    }
    $script:IsFreeHandActive = $true; $script:IsTestRunning = $false
	$pnlConfig.Invalidate($true); $btnFreeHand.Invalidate()
    $txtMaster.Text = ""; $txtMaster.ReadOnly = $true; $lblMaster.Visible = $false
    $btnCopyMaster.Visible = $false; $btnPasteMaster.Visible = $false; $btnClearMaster.Visible = $false
    $lblLiveStats.Visible = $true; $lblTimerDisplay.Visible = $true; $btnStartFreeHand.Visible = $true; $btnSubmitTest.Visible = $false
    $lblTimerDisplay.Text = "WAITING"
    $lblLiveStats.Text = "Strokes: 0  |  Speed: 0.0 WPM  |  Backspaces: 0"
})

$btnStartFreeHand.Add_Click({
    if ($script:AppMode -eq "Comparison") {
        if ([string]::IsNullOrWhiteSpace($txtPath.Text) -or -not (Test-Path $txtPath.Text)) {
            [System.Windows.Forms.MessageBox]::Show("Comparison Mode requires a Master File. Please browse and select your Master File at the top before starting the test.", "Master File Required", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
    }
    $duration = 10.0
    if (![double]::TryParse($txtTime.Text, [ref]$duration) -or $duration -le 0) { $duration = 10.0 }
    $script:FreeHandTotalSeconds = $duration * 60; $script:FreeHandSecondsLeft = $script:FreeHandTotalSeconds
    $btnStartFreeHand.Visible = $false; $script:CountdownSeconds = 3; $script:IsTestRunning = $false; $lblTimerDisplay.Text = "Starts in 3..."
    $txtMaster.Text = ""; $txtMaster.ReadOnly = $true; $script:BackspaceCount = 0; $LiveTimer.Start()
})

$btnCalc.Add_Click({
    if ($script:IsTestRunning) { return }
    $btnCalc.Enabled = $false
    try {
        $duration = 10.0
        if (![double]::TryParse($txtTime.Text, [ref]$duration) -or $duration -le 0) { $duration = 10.0 }
        $typedText = ""
        $boxText = $txtMaster.Text.Trim()

        if ($script:AppMode -eq "Dictionary") {
            if (-not [string]::IsNullOrWhiteSpace($boxText)) { $typedText = $boxText } else {
                if ([string]::IsNullOrWhiteSpace($txtPath.Text) -or -not (Test-Path $txtPath.Text)) {
                    [System.Windows.Forms.MessageBox]::Show("Please select a Target File or paste text below.", "Validation")
                    return
                }
                $rawText = Get-Content $txtPath.Text -Raw -Encoding UTF8
                if ($null -ne $rawText) { $typedText = $rawText -replace "`r`n", "`n" }
            }
            $txtOutput.Text = "`r`n  Initializing evaluation engine..."
            [System.Windows.Forms.Application]::DoEvents()
            $script:LastScale = 2.0 
            [array]$errorsArray = Run-StandaloneEngine -TextData $typedText
        } else {
            if ([string]::IsNullOrWhiteSpace($txtPath.Text) -or -not (Test-Path $txtPath.Text)) {
                [System.Windows.Forms.MessageBox]::Show("Please select a Master File for comparison.", "Validation")
                return
            }
            if ([string]::IsNullOrWhiteSpace($boxText)) {
                [System.Windows.Forms.MessageBox]::Show("Please paste your Typed Text into the box.", "Validation")
                return
            }
            $rawText = Get-Content $txtPath.Text -Raw -Encoding UTF8
            $masterTextFile = if ($null -ne $rawText) { $rawText -replace "`r`n", "`n" } else { "" }
            $typedText = $boxText
            $script:LastScale = 2.0
            [array]$errorsArray = Run-ComparisonEngine -TypedText $typedText -MasterText $masterTextFile
        }

        $spamResult = Invoke-AntiSpamFilter -InputText $typedText -EngineErrors $errorsArray
        $script:LastGrossStrokes = $typedText.Length - $spamResult.SpamStrokes
        if ($script:LastGrossStrokes -lt 0) { $script:LastGrossStrokes = 0 }
        $script:LastGrossWords = $script:LastGrossStrokes / 5.0
        $script:CurrentErrorObjects = $spamResult.FinalErrors
        $script:IgnoredErrorIndices = @()
        $script:LastDuration = $duration; $script:HasRun = $true

        Invoke-RenderScoreboard; Invoke-HighlightTextBoxErrors
    } finally { $btnCalc.Enabled = $true }
})

# Recalculates sizes and positions of UI elements when window resizes
function Invoke-UpdateLayout {
    if ($form.WindowState -ne [System.Windows.Forms.FormWindowState]::Minimized) {
        $form.SuspendLayout()
        $newW = $form.ClientSize.Width - 60
        if ($newW -lt 100) { $newW = 100 }

        $pnlConfig.Left = 30; $pnlConfig.Width = $newW
        $pnlMaster.Left = 30; $pnlMaster.Width = $newW
        $btnCalc.Left = 30; $btnCalc.Width = $newW
        $pnlOutput.Left = 30; $pnlOutput.Width = $newW

        $btnBrowse.Left = $pnlConfig.Width - $btnBrowse.Width - 15
        $btnToggleEngine.Left = $btnBrowse.Left - $btnToggleEngine.Width - 15; $btnToggleEngine.Top = 20
        $txtPath.Width = $btnToggleEngine.Left - $txtPath.Left - 15
        $remainingHeight = $form.ClientSize.Height - $pnlMaster.Top - 90 
        if ($remainingHeight -lt 300) { $remainingHeight = 300 }
        $pnlMaster.Height = [int]($remainingHeight * 0.45)
        
        $btnSubmitTest.Width = 100; $btnSubmitTest.Height = 32; $btnSubmitTest.Top = 12
        $btnSubmitTest.Left = $pnlMaster.Width - $btnSubmitTest.Width - 20
        $lblTimerDisplay.Top = 10; $lblTimerDisplay.Width = 160; $lblTimerDisplay.Height = 35
        $lblTimerDisplay.Left = $btnSubmitTest.Left - $lblTimerDisplay.Width - 5
        $lblLiveStats.Top = 22; $lblLiveStats.Left = 20; $lblLiveStats.Width = $lblTimerDisplay.Left - $lblLiveStats.Left - 10

        $btnStartFreeHand.Width = 280; $btnStartFreeHand.Height = 60
        $btnStartFreeHand.Left = ($pnlMaster.Width - $btnStartFreeHand.Width) / 2; $btnStartFreeHand.Top = ($pnlMaster.Height - $btnStartFreeHand.Height) / 2

        $btnCopyMaster.Width = 35; $btnCopyMaster.Height = 24
        $btnPasteMaster.Width = 35; $btnPasteMaster.Height = 24
        $btnClearMaster.Width = 35; $btnClearMaster.Height = 24

        if ($script:IsFreeHandActive) {
            $btnCopyMaster.Visible = $false; $btnPasteMaster.Visible = $false; $btnClearMaster.Visible = $false
        } else {
            $btnCopyMaster.Visible = $true; $btnPasteMaster.Visible = $true; $btnClearMaster.Visible = $true
            $btnClearMaster.Left = $pnlMaster.Width - $btnClearMaster.Width - 20
            $btnPasteMaster.Left = $btnClearMaster.Left - $btnPasteMaster.Width - 8
            $btnCopyMaster.Left = $btnPasteMaster.Left - $btnCopyMaster.Width - 8
        }
        $btnCopyMaster.Top = 13; $btnPasteMaster.Top = 13; $btnClearMaster.Top = 13
        if ($script:IsFreeHandActive) { $lblMaster.Width = $pnlMaster.Width - 40 } else { $lblMaster.Width = $btnCopyMaster.Left - $lblMaster.Left - 10 }

        $txtMaster.Width = $pnlMaster.Width - ($txtMaster.Left * 2)
        $txtMaster.Height = $pnlMaster.Height - $txtMaster.Top - 15
        $btnCalc.Top = $pnlMaster.Top + $pnlMaster.Height + 15
        $pnlOutput.Top = $btnCalc.Top + $btnCalc.Height + 15
        $pnlOutput.Height = $form.ClientSize.Height - $pnlOutput.Top - 45
        $lblVersion.Left = $form.ClientSize.Width - $lblVersion.Width - 30; $lblVersion.Top = $form.ClientSize.Height - $lblVersion.Height - 15

        $scale = $form.Width / 850.0
        $newOutputSize = [float]([math]::Max(10.0, 10.0 + (($scale - 1) * 2)))
        if ([math]::Abs($txtOutput.Font.Size - $newOutputSize) -gt 0.5) { $txtOutput.Font = New-Object System.Drawing.Font("Consolas", $newOutputSize) }
        $newMasterSize = [float]([math]::Max(13.5, 13.5 + (($scale - 1) * 2.25)))
        if ([math]::Abs($txtMaster.Font.Size - $newMasterSize) -gt 0.5) { $txtMaster.Font = New-Object System.Drawing.Font("Segoe UI", $newMasterSize) }
        $newBtnSize = [float]([math]::Max(10.0, 10.0 + (($scale - 1) * 1.5)))
        if ([math]::Abs($btnCalc.Font.Size - $newBtnSize) -gt 0.5) { $btnCalc.Font = New-Object System.Drawing.Font("Segoe UI", $newBtnSize, [System.Drawing.FontStyle]::Bold) }
        
        $form.ResumeLayout($true)
        if ($script:HasRun) { Invoke-HighlightTextBoxErrors }
        Invoke-BoldNetSpeedLogic
    }
}

$btnToggleUnit.Add_Click({
    if ($script:IsTestRunning) { return }
    if ($script:UnitMode -eq "Strokes") { $script:UnitMode = "Words"; $btnToggleUnit.Text = "Data: Words" } else { $script:UnitMode = "Strokes"; $btnToggleUnit.Text = "Data: Strokes" }
    $btnToggleUnit.Invalidate(); Invoke-RenderScoreboard
})

$btnIgnore.Add_Click({
    if ($script:IsTestRunning) { return }
    if (-not $script:HasRun -or $script:CurrentErrorObjects.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("Please execute a run analysis first and ensure errors are detected before setting exclusions.", "Action Required"); return }
    
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Select System Errors to Exclude"; $dialog.Size = New-Object System.Drawing.Size(600, 480); $dialog.MinimumSize = New-Object System.Drawing.Size(500, 400); $dialog.StartPosition = "CenterParent"; $dialog.Font = New-Object System.Drawing.Font("Segoe UI", 9.5); $dialog.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#F1F5F9"); $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog; $dialog.MaximizeBox = $false; $dialog.MinimizeBox = $false

    $lblMsg = New-Object System.Windows.Forms.Label
    $lblMsg.Text = "Check the specific error components you wish to ignore from compliance scores:"; $lblMsg.Location = New-Object System.Drawing.Point(20, 15); $lblMsg.Size = New-Object System.Drawing.Size(540, 25); $lblMsg.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#334155")
    $dialog.Controls.Add($lblMsg)

    $clb = New-Object System.Windows.Forms.CheckedListBox
    $clb.Location = New-Object System.Drawing.Point(20, 50); $clb.Size = New-Object System.Drawing.Size(545, 310); $clb.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle; $clb.CheckOnClick = $true; $clb.BackColor = [System.Drawing.Color]::White; $clb.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#0F172A")

    for ($i = 0; $i -lt $script:CurrentErrorObjects.Count; $i++) {
        $errNum = $i + 1; $displayTxt = "[$errNum] $($script:CurrentErrorObjects[$i].Text)"; [void]$clb.Items.Add($displayTxt)
        if ($script:IgnoredErrorIndices -contains $errNum) { $clb.SetItemChecked($i, $true) }
    }
    $dialog.Controls.Add($clb)

    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = "Apply Exclusions"; $btnOK.DialogResult = [System.Windows.Forms.DialogResult]::OK; $btnOK.Location = New-Object System.Drawing.Point(300, 385); $btnOK.Size = New-Object System.Drawing.Size(150, 32); $btnOK.FlatStyle = [System.Windows.Forms.FlatStyle]::System
    $dialog.Controls.Add($btnOK)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"; $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $btnCancel.Location = New-Object System.Drawing.Point(460, 385); $btnCancel.Size = New-Object System.Drawing.Size(105, 32); $btnCancel.FlatStyle = [System.Windows.Forms.FlatStyle]::System
    $dialog.Controls.Add($btnCancel)

    $dialog.AcceptButton = $btnOK; $dialog.CancelButton = $btnCancel

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $newIgnored = @()
        for ($i = 0; $i -lt $clb.Items.Count; $i++) { if ($clb.GetItemChecked($i)) { $newIgnored += ($i + 1) } }
        $script:IgnoredErrorIndices = $newIgnored
        Invoke-RenderScoreboard; Invoke-HighlightTextBoxErrors
    }
    $dialog.Dispose()
})

# Boot up logic mapping
$form.Add_Resize({ Invoke-UpdateLayout; $form.Invalidate($true) })
$form.Add_Shown({ Invoke-UpdateLayout; $form.Invalidate($true); $form.Refresh() })
[void]$form.ShowDialog()
