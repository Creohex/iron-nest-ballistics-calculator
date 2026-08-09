[CmdletBinding()]
param(
    [double]$RangeMeters = 0,
    [ValidateSet('fast', 'minimum')]
    [string]$Mode = 'fast',
    [switch]$NoVoice,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-BallisticSolution {
    param(
        [Parameter(Mandatory)]
        [double]$Range,
        [ValidateSet('fast', 'minimum')]
        [string]$RecommendationMode = 'fast'
    )

    if ($Range -le 0) {
        throw 'Range must be greater than 0 meters.'
    }
    if ($Range -gt 30000) {
        throw 'Target is out of range. The maximum range is 30,000 meters.'
    }

    $minimumCharges = [int][Math]::Ceiling($Range / 5000.0)
    $recommendedCharges = $minimumCharges
    if ($RecommendationMode -eq 'fast' -and $minimumCharges -lt 6) {
        $recommendedCharges++
    }

    $recommendedAngle = $Range * 60.0 / ($recommendedCharges * 5000.0)
    $minimumAngle = $Range * 60.0 / ($minimumCharges * 5000.0)

    [pscustomobject]@{
        RangeMeters       = $Range
        Charges           = $recommendedCharges
        AngleDegrees      = [Math]::Round($recommendedAngle, 1)
        MinimumCharges    = $minimumCharges
        MinimumAngle      = [Math]::Round($minimumAngle, 1)
        UsesExtraCharge   = $recommendedCharges -gt $minimumCharges
    }
}

$script:numberWords = @{
    zero=0; oh=0; one=1; two=2; three=3; four=4; five=5; six=6; seven=7; eight=8; nine=9
    ten=10; eleven=11; twelve=12; thirteen=13; fourteen=14; fifteen=15; sixteen=16
    seventeen=17; eighteen=18; nineteen=19; twenty=20; thirty=30; forty=40; fifty=50
    sixty=60; seventy=70; eighty=80; ninety=90
}

function Convert-EnglishInteger {
    param([Parameter(Mandatory)][string[]]$Tokens)

    $current = 0.0
    $total = 0.0
    $found = $false
    foreach ($token in $Tokens) {
        if (-not $token -or $token -in @('and', 'a', 'of')) { continue }
        if ($token -match '^\d+$') {
            $current += [double]::Parse($token, [Globalization.CultureInfo]::InvariantCulture)
            $found = $true
        }
        elseif ($script:numberWords.ContainsKey($token)) {
            $current += $script:numberWords[$token]
            $found = $true
        }
        elseif ($token -eq 'hundred') {
            if ($current -eq 0) { $current = 1 }
            $current *= 100
            $found = $true
        }
        elseif ($token -eq 'thousand') {
            if ($current -eq 0) { $current = 1 }
            $total += $current * 1000
            $current = 0
            $found = $true
        }
    }
    if (-not $found) { throw 'No English number was found.' }
    return $total + $current
}

function Convert-SpokenRange {
    param([Parameter(Mandatory)][string]$Text)

    $normalized = $Text.ToLowerInvariant().Replace(',', '') -replace '-', ' '
    $explicitMeters = $normalized -match '\b(meters?|metres?|m)\b'
    $explicitKilometers = $normalized -match '\b(kilometers?|kilometres?|kms?|km)\b'

    # Recognizers commonly return spoken numbers as digits. A decimal without a
    # stated unit is treated as kilometers: "5.25" means 5,250 meters.
    $numberMatch = [regex]::Match(
        $normalized,
        '^\s*(\d+(?:\.\d+)?)\s*(?:kilometers?|kilometres?|kms?|km|meters?|metres?|m)?\s*$'
    )
    if ($numberMatch.Success) {
        $numericText = $numberMatch.Groups[1].Value
        $value = [double]::Parse($numericText, [Globalization.CultureInfo]::InvariantCulture)
        if ($explicitKilometers -or ($numericText.Contains('.') -and -not $explicitMeters)) {
            $value *= 1000
        }
        return $value
    }

    $tokens = @([regex]::Matches($normalized, '[a-z]+|\d+') | ForEach-Object { $_.Value } | Where-Object {
        $_ -and ($_ -match '^\d+$' -or $script:numberWords.ContainsKey($_) -or $_ -in @('hundred', 'thousand', 'point', 'and', 'a', 'of', 'meter', 'meters', 'metre', 'metres', 'kilometer', 'kilometers', 'kilometre', 'kilometres', 'km'))
    })
    $numberTokens = @($tokens | Where-Object {
        $_ -match '^\d+$' -or $script:numberWords.ContainsKey($_) -or $_ -in @('hundred', 'thousand', 'point', 'and', 'a', 'of')
    })
    if ($numberTokens.Count -eq 0) { throw "I couldn't find a range in '$Text'." }

    $pointIndex = [Array]::IndexOf($numberTokens, 'point')
    if ($pointIndex -ge 0) {
        if ($pointIndex -eq 0 -or $pointIndex -eq $numberTokens.Count - 1) {
            throw "I couldn't understand the decimal range in '$Text'."
        }
        $left = Convert-EnglishInteger @($numberTokens[0..($pointIndex - 1)])
        $rightTokens = @($numberTokens[($pointIndex + 1)..($numberTokens.Count - 1)])
        if (@($rightTokens | Where-Object {
            -not (($_ -match '^\d$') -or ($script:numberWords.ContainsKey($_) -and $script:numberWords[$_] -le 9))
        }).Count -eq 0) {
            $decimalText = -join @($rightTokens | ForEach-Object {
                if ($_ -match '^\d$') { $_ } else { [string]$script:numberWords[$_] }
            })
        }
        else {
            $decimalText = [string][int](Convert-EnglishInteger $rightTokens)
        }
        $value = $left + ([double]::Parse("0.$decimalText", [Globalization.CultureInfo]::InvariantCulture))
        if (-not $explicitMeters) { $value *= 1000 }
        return $value
    }

    # Explicit kilometers can include a meter remainder: "five kilometers two
    # hundred fifty" becomes 5,250 meters.
    if ($explicitKilometers) {
        $unitIndex = -1
        for ($i = 0; $i -lt $tokens.Count; $i++) {
            if ($tokens[$i] -match '^(km|kilometers?|kilometres?)$') { $unitIndex = $i; break }
        }
        $before = @($tokens[0..($unitIndex - 1)] | Where-Object { $_ -notin @('and', 'a', 'of') })
        $kilometers = Convert-EnglishInteger $before
        $meters = 0
        if ($unitIndex -lt $tokens.Count - 1) {
            $after = @($tokens[($unitIndex + 1)..($tokens.Count - 1)] | Where-Object {
                $script:numberWords.ContainsKey($_) -or $_ -in @('hundred', 'thousand', 'and')
            })
            if ($after.Count -gt 0) { $meters = Convert-EnglishInteger $after }
        }
        return ($kilometers * 1000) + $meters
    }

    $plainTokens = @($numberTokens | Where-Object { $_ -notin @('and', 'a', 'of') })
    $hasScaleWord = @($plainTokens | Where-Object { $_ -in @('hundred', 'thousand') }).Count -gt 0

    # Compact artillery-style wording: "five twenty five" is interpreted as
    # 5.25 km. "Twelve fifty" similarly means 12.50 km. Phrases containing
    # hundred/thousand retain their ordinary meter meaning.
    if (-not $hasScaleWord -and $plainTokens.Count -ge 2 -and
        ($script:numberWords.ContainsKey($plainTokens[0]) -or $plainTokens[0] -match '^\d+$')) {
        $whole = if ($plainTokens[0] -match '^\d+$') { [int]$plainTokens[0] } else { [int]$script:numberWords[$plainTokens[0]] }
        $remainderTokens = @($plainTokens[1..($plainTokens.Count - 1)])
        $secondValue = if ($plainTokens[1] -match '^\d+$') { [int]$plainTokens[1] } else { [int]$script:numberWords[$plainTokens[1]] }
        $looksCompact = ($plainTokens.Count -ge 3) -or ($secondValue -ge 10)
        if ($looksCompact -and $whole -le 30) {
            $allSingleDigits = @($remainderTokens | Where-Object {
                -not (($_ -match '^\d$') -or ($script:numberWords.ContainsKey($_) -and $script:numberWords[$_] -le 9))
            }).Count -eq 0
            if ($allSingleDigits) {
                $decimalText = -join @($remainderTokens | ForEach-Object {
                    if ($_ -match '^\d$') { $_ } else { [string]$script:numberWords[$_] }
                })
            }
            else {
                $decimalText = [string][int](Convert-EnglishInteger $remainderTokens)
            }
            return ($whole + [double]::Parse("0.$decimalText", [Globalization.CultureInfo]::InvariantCulture)) * 1000
        }
    }

    return Convert-EnglishInteger $numberTokens
}

function Test-RangeUtterance {
    param([Parameter(Mandatory)][string]$Text)

    $normalized = $Text.ToLowerInvariant() -replace '-', ' '
    $hasNumber = $normalized -match '\d' -or @($script:numberWords.Keys | Where-Object {
        $normalized -match "\b$([regex]::Escape($_))\b"
    }).Count -gt 0
    if (-not $hasNumber) { return $false }

    $words = @($normalized -split '[^a-z]+' | Where-Object { $_ })
    $allowed = @(
        'hundred', 'thousand', 'point', 'and', 'a', 'of',
        'meter', 'meters', 'metre', 'metres',
        'kilometer', 'kilometers', 'kilometre', 'kilometres', 'km', 'kms'
    )
    foreach ($word in $words) {
        if (-not $script:numberWords.ContainsKey($word) -and $word -notin $allowed) {
            return $false
        }
    }
    return $true
}

function Format-Angle {
    param([double]$Angle)
    if ($Angle -eq [Math]::Truncate($Angle)) { return ('{0:0}' -f $Angle) }
    return ('{0:0.0}' -f $Angle)
}

function Format-Range {
    param([double]$Range)
    return ('{0:N0}' -f $Range)
}

function Get-SolutionText {
    param([Parameter(Mandatory)]$Solution)
    $angle = Format-Angle $Solution.AngleDegrees
    return "$($Solution.Charges), $angle degrees"
}

if ($SelfTest) {
    $tests = @(
        @{ Name = 'fast recommendation'; Actual = (Get-BallisticSolution 12000 fast).Charges; Expected = 4 }
        @{ Name = 'fast angle'; Actual = (Get-BallisticSolution 12000 fast).AngleDegrees; Expected = 36.0 }
        @{ Name = 'minimum recommendation'; Actual = (Get-BallisticSolution 12000 minimum).Charges; Expected = 3 }
        @{ Name = 'maximum boundary'; Actual = (Get-BallisticSolution 30000 fast).AngleDegrees; Expected = 60.0 }
        @{ Name = 'spoken thousands'; Actual = (Convert-SpokenRange 'twelve thousand meters'); Expected = 12000.0 }
        @{ Name = 'spoken kilometers'; Actual = (Convert-SpokenRange 'twelve kilometers'); Expected = 12000.0 }
        @{ Name = 'spoken numeric km'; Actual = (Convert-SpokenRange '12.5 km'); Expected = 12500.0 }
        @{ Name = 'spoken compound number'; Actual = (Convert-SpokenRange 'twenty five thousand'); Expected = 25000.0 }
        @{ Name = 'compact twenty-five'; Actual = (Convert-SpokenRange 'five twenty five'); Expected = 5250.0 }
        @{ Name = 'compact seventy-five'; Actual = (Convert-SpokenRange 'six seventy five'); Expected = 6750.0 }
        @{ Name = 'numeric six point seventy-five'; Actual = (Convert-SpokenRange '6.75'); Expected = 6750.0 }
        @{ Name = 'compact with meter suffix'; Actual = (Convert-SpokenRange 'five twenty five meters'); Expected = 5250.0 }
        @{ Name = 'compact separate digits'; Actual = (Convert-SpokenRange 'five two five'); Expected = 5250.0 }
        @{ Name = 'spoken decimal'; Actual = (Convert-SpokenRange 'five point two five'); Expected = 5250.0 }
        @{ Name = 'numeric meters'; Actual = (Convert-SpokenRange '5250'); Expected = 5250.0 }
        @{ Name = 'numeric decimal kilometers'; Actual = (Convert-SpokenRange '5.25'); Expected = 5250.0 }
        @{ Name = 'full meter wording'; Actual = (Convert-SpokenRange 'five thousand two hundred fifty'); Expected = 5250.0 }
        @{ Name = 'mixed kilometer wording'; Actual = (Convert-SpokenRange 'five kilometers two hundred fifty'); Expected = 5250.0 }
        @{ Name = 'ordinary twenty-five meters'; Actual = (Convert-SpokenRange 'twenty five'); Expected = 25.0 }
        @{ Name = 'ten-thousand full words'; Actual = (Convert-SpokenRange 'ten thousand two hundred fifty'); Expected = 10250.0 }
        @{ Name = 'ten-thousand mixed suffix'; Actual = (Convert-SpokenRange 'ten thousand 250'); Expected = 10250.0 }
        @{ Name = 'numeric ten-thousand mixed suffix'; Actual = (Convert-SpokenRange '10 thousand 250'); Expected = 10250.0 }
        @{ Name = 'ten-thousand compact'; Actual = (Convert-SpokenRange 'ten twenty five'); Expected = 10250.0 }
        @{ Name = 'ten-point numeric suffix'; Actual = (Convert-SpokenRange 'ten point 25'); Expected = 10250.0 }
        @{ Name = 'numeric ten-point suffix'; Actual = (Convert-SpokenRange '10 point 25'); Expected = 10250.0 }
        @{ Name = 'ten-point word suffix'; Actual = (Convert-SpokenRange 'ten point twenty five'); Expected = 10250.0 }
        @{ Name = 'eleven-thousand mixed suffix'; Actual = (Convert-SpokenRange 'eleven thousand 725'); Expected = 11725.0 }
        @{ Name = 'ten-thousand small suffix'; Actual = (Convert-SpokenRange 'ten thousand twenty five'); Expected = 10025.0 }
        @{ Name = 'standalone range utterance'; Actual = (Test-RangeUtterance 'six seventy five'); Expected = $true }
        @{ Name = 'ordinary speech ignored'; Actual = (Test-RangeUtterance 'there are six targets'); Expected = $false }
    )
    foreach ($test in $tests) {
        if ([double]$test.Actual -ne [double]$test.Expected) {
            throw "Self-test '$($test.Name)' failed: expected $($test.Expected), got $($test.Actual)."
        }
    }
    try {
        [void](Get-BallisticSolution 30001 fast)
        throw 'Self-test failed: an out-of-range target was accepted.'
    }
    catch {
        if ($_.Exception.Message -notlike 'Target is out of range*') { throw }
    }
    Write-Output "All $($tests.Count + 1) self-tests passed."
    exit 0
}

if ($PSBoundParameters.ContainsKey('RangeMeters')) {
    try {
        $solution = Get-BallisticSolution -Range $RangeMeters -RecommendationMode $Mode
        $main = Get-SolutionText $solution
        Write-Output "Range: $(Format-Range $solution.RangeMeters) m"
        Write-Output "Recommended: $main"
        if ($solution.UsesExtraCharge) {
            Write-Output "Minimum-charge option: $($solution.MinimumCharges) charges at $(Format-Angle $solution.MinimumAngle) degrees"
        }
        exit 0
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:synthesizer = $null
$script:sapiVoice = $null
try {
    Add-Type -AssemblyName System.Speech
    $script:synthesizer = [System.Speech.Synthesis.SpeechSynthesizer]::new()
    if ($script:synthesizer.GetInstalledVoices().Count -eq 0) {
        $script:synthesizer.Dispose()
        $script:synthesizer = $null
    }
}
catch {
    if ($null -ne $script:synthesizer) { $script:synthesizer.Dispose() }
    $script:synthesizer = $null
}
if ($null -eq $script:synthesizer) {
    try {
        # Legacy Windows SAPI is widely available, even without a speech language pack.
        $script:sapiVoice = New-Object -ComObject SAPI.SpVoice
    }
    catch {
        # The visual calculator still works if all speech components are absent.
    }
}
$script:ignoreRecognitionUntil = [DateTime]::MinValue

function Speak-Text {
    param([string]$Text)
    if ($NoVoice) { return }
    # Numeric replies would otherwise be heard as fresh range commands. Speaking
    # synchronously lets us discard microphone transcripts produced by our own voice.
    $script:ignoreRecognitionUntil = [DateTime]::UtcNow.AddMinutes(1)
    try {
        if ($null -ne $script:synthesizer) {
            $script:synthesizer.SpeakAsyncCancelAll()
            $script:synthesizer.Speak($Text)
        }
        elseif ($null -ne $script:sapiVoice) {
            [void]$script:sapiVoice.Speak($Text, 0)
        }
    }
    catch {
        # Speech output is optional; never hide an otherwise valid solution.
    }
    finally {
        $script:ignoreRecognitionUntil = [DateTime]::UtcNow.AddMilliseconds(900)
    }
}

$form = [Windows.Forms.Form]::new()
$form.Text = 'IRON NEST Ballistics'
$form.ClientSize = [Drawing.Size]::new(560, 390)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.BackColor = [Drawing.Color]::FromArgb(24, 28, 34)
$form.ForeColor = [Drawing.Color]::White
$form.Font = [Drawing.Font]::new('Segoe UI', 10)

$title = [Windows.Forms.Label]::new()
$title.Text = 'IRON NEST BALLISTICS'
$title.Font = [Drawing.Font]::new('Segoe UI Semibold', 20)
$title.ForeColor = [Drawing.Color]::FromArgb(240, 181, 63)
$title.AutoSize = $true
$title.Location = [Drawing.Point]::new(24, 20)
$form.Controls.Add($title)

$prompt = [Windows.Forms.Label]::new()
$prompt.Text = 'Target range (meters)'
$prompt.AutoSize = $true
$prompt.Location = [Drawing.Point]::new(27, 72)
$form.Controls.Add($prompt)

$rangeBox = [Windows.Forms.TextBox]::new()
$rangeBox.Font = [Drawing.Font]::new('Segoe UI', 18)
$rangeBox.Location = [Drawing.Point]::new(30, 96)
$rangeBox.Size = [Drawing.Size]::new(300, 42)
$rangeBox.Text = ''
$form.Controls.Add($rangeBox)

$listenButton = [Windows.Forms.Button]::new()
$listenButton.Text = 'MIC  Starting...'
$listenButton.Location = [Drawing.Point]::new(345, 97)
$listenButton.Size = [Drawing.Size]::new(180, 40)
$listenButton.BackColor = [Drawing.Color]::FromArgb(55, 63, 74)
$listenButton.ForeColor = [Drawing.Color]::White
$listenButton.FlatStyle = 'Flat'
$form.Controls.Add($listenButton)

$fastAimCheck = [Windows.Forms.CheckBox]::new()
$fastAimCheck.Text = 'Use one extra charge for faster aiming'
$fastAimCheck.Checked = $true
$fastAimCheck.AutoSize = $true
$fastAimCheck.Location = [Drawing.Point]::new(30, 151)
$form.Controls.Add($fastAimCheck)

$calculateButton = [Windows.Forms.Button]::new()
$calculateButton.Text = 'CALCULATE'
$calculateButton.Font = [Drawing.Font]::new('Segoe UI Semibold', 12)
$calculateButton.Location = [Drawing.Point]::new(30, 190)
$calculateButton.Size = [Drawing.Size]::new(495, 46)
$calculateButton.BackColor = [Drawing.Color]::FromArgb(196, 126, 35)
$calculateButton.ForeColor = [Drawing.Color]::White
$calculateButton.FlatStyle = 'Flat'
$form.Controls.Add($calculateButton)

$resultLabel = [Windows.Forms.Label]::new()
$resultLabel.Text = 'Enter a range from 1 to 30,000 meters.'
$resultLabel.Font = [Drawing.Font]::new('Segoe UI Semibold', 19)
$resultLabel.ForeColor = [Drawing.Color]::FromArgb(126, 211, 153)
$resultLabel.AutoSize = $false
$resultLabel.TextAlign = 'MiddleCenter'
$resultLabel.Location = [Drawing.Point]::new(30, 251)
$resultLabel.Size = [Drawing.Size]::new(495, 48)
$form.Controls.Add($resultLabel)

$detailLabel = [Windows.Forms.Label]::new()
$detailLabel.Text = ''
$detailLabel.ForeColor = [Drawing.Color]::LightGray
$detailLabel.AutoSize = $false
$detailLabel.TextAlign = 'MiddleCenter'
$detailLabel.Location = [Drawing.Point]::new(30, 302)
$detailLabel.Size = [Drawing.Size]::new(495, 28)
$form.Controls.Add($detailLabel)

$statusLabel = [Windows.Forms.Label]::new()
$statusLabel.Text = 'Starting continuous listener...'
$statusLabel.ForeColor = [Drawing.Color]::Gray
$statusLabel.AutoSize = $false
$statusLabel.TextAlign = 'MiddleCenter'
$statusLabel.Location = [Drawing.Point]::new(30, 344)
$statusLabel.Size = [Drawing.Size]::new(495, 25)
$form.Controls.Add($statusLabel)

$script:lastAnswer = $null
$script:lastAngleAnswer = $null
$script:lastChargesAnswer = $null
$script:lastRangeAnswer = $null
$script:includeRangeInNextAnswer = $false

$calculate = {
    $includeRange = $script:includeRangeInNextAnswer
    $script:includeRangeInNextAnswer = $false
    try {
        $range = Convert-SpokenRange $rangeBox.Text
        $selectedMode = if ($fastAimCheck.Checked) { 'fast' } else { 'minimum' }
        $solution = Get-BallisticSolution -Range $range -RecommendationMode $selectedMode
        $answer = Get-SolutionText $solution
        if ($includeRange) {
            $answer = "$(Format-Range $solution.RangeMeters), $($solution.Charges) charges"
        }
        $resultLabel.ForeColor = [Drawing.Color]::FromArgb(126, 211, 153)
        $resultLabel.Text = $answer.ToUpperInvariant()
        if ($includeRange) {
            $detailLabel.Text = 'Say Angle, Charges, Distance, or Repeat.'
        }
        elseif ($solution.UsesExtraCharge) {
            $minimumWord = if ($solution.MinimumCharges -eq 1) { 'charge' } else { 'charges' }
            $detailLabel.Text = "Minimum: $($solution.MinimumCharges) $minimumWord at $(Format-Angle $solution.MinimumAngle) degrees"
        }
        else {
            $detailLabel.Text = "Maximum range with $($solution.Charges) charges: $($solution.Charges * 5000) m"
        }
        $statusLabel.Text = "Solution for $(Format-Range $solution.RangeMeters) meters"
        $script:lastAnswer = $answer
        $script:lastAngleAnswer = "$(Format-Angle $solution.AngleDegrees) degrees"
        $script:lastChargesAnswer = [string]$solution.Charges
        $script:lastRangeAnswer = Format-Range $solution.RangeMeters
        Speak-Text $answer
    }
    catch {
        $resultLabel.ForeColor = [Drawing.Color]::FromArgb(244, 112, 112)
        $resultLabel.Text = 'INVALID RANGE'
        $detailLabel.Text = $_.Exception.Message
        Speak-Text $_.Exception.Message
    }
}

$calculateButton.Add_Click($calculate)
$rangeBox.Add_KeyDown({
    if ($_.KeyCode -eq [Windows.Forms.Keys]::Enter) {
        $_.SuppressKeyPress = $true
        & $calculate
    }
})

$script:speechQueue = [Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:recognizer = $null
$script:recognitionActive = $false
$script:recognitionWanted = $true
$script:closing = $false
$script:wakeDeadline = [DateTime]::MinValue
$script:recognizerGeneration = 0
$script:speechRecognizedHandler = $null
$script:recognizeCompletedHandler = $null

function Stop-ContinuousListening {
    param([bool]$DisableRestart = $true)

    if ($DisableRestart) { $script:recognitionWanted = $false }
    $script:recognitionActive = $false
    if ($null -ne $script:recognizer) {
        try { $script:recognizer.RecognizeAsyncCancel() } catch {}
        try { $script:recognizer.SetInputToNull() } catch {}
        try { $script:recognizer.Dispose() } catch {}
        $script:recognizer = $null
    }
    $listenButton.Text = 'MIC  Paused'
    $listenButton.BackColor = [Drawing.Color]::FromArgb(95, 72, 58)
}

function Start-ContinuousListening {
    if ($script:recognitionActive -or $script:closing) { return }
    $script:recognitionWanted = $true

    try {
        Add-Type -AssemblyName System.Speech
        $installed = @([System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers())
        $englishRecognizers = @($installed | Where-Object { $_.Culture.Name -like 'en-*' } | Sort-Object {
            if ($_.Culture.Name -eq 'en-US') { 0 } else { 1 }
        })
        if ($englishRecognizers.Count -eq 0) {
            throw 'No English recognizer is installed. Restart Windows after installing English Speech under Language options.'
        }

        $selectedRecognizer = $englishRecognizers[0]
        $script:recognizer = [System.Speech.Recognition.SpeechRecognitionEngine]::new($selectedRecognizer)
        $dictation = [System.Speech.Recognition.DictationGrammar]::new()
        $dictation.Name = 'English numbers'
        $script:recognizer.LoadGrammar($dictation)

        # A small dedicated grammar makes short control words substantially more
        # reliable than relying on free-form dictation alone, especially with accents.
        $commandChoices = [System.Speech.Recognition.Choices]::new()
        $commandChoices.Add([string[]]@(
            'repeat', 'repeat that', 'angle', 'charges',
            'current', 'current range', 'distance'
        ))
        $commandBuilder = [System.Speech.Recognition.GrammarBuilder]::new()
        $commandBuilder.Culture = $selectedRecognizer.Culture
        $commandBuilder.Append($commandChoices)
        $commandGrammar = [System.Speech.Recognition.Grammar]::new($commandBuilder)
        $commandGrammar.Name = 'Voice commands'
        $script:recognizer.LoadGrammar($commandGrammar)
        $script:recognizer.SetInputToDefaultAudioDevice()

        $queue = $script:speechQueue
        $queueSeparator = [char]31
        $script:recognizerGeneration++
        $generation = $script:recognizerGeneration
        $script:speechRecognizedHandler = {
            param($sender, $eventArgs)
            if ($null -ne $eventArgs.Result -and $eventArgs.Result.Confidence -ge 0.30) {
                $displayText = $eventArgs.Result.Text
                $lexicalText = @($eventArgs.Result.Words | ForEach-Object { $_.LexicalForm }) -join ' '
                $queue.Enqueue("$displayText$queueSeparator$lexicalText")
            }
        }.GetNewClosure()
        $script:recognizeCompletedHandler = {
            param($sender, $eventArgs)
            $queue.Enqueue("__RECOGNIZER_ENDED__:$generation")
        }.GetNewClosure()
        $script:recognizer.add_SpeechRecognized($script:speechRecognizedHandler)
        $script:recognizer.add_RecognizeCompleted($script:recognizeCompletedHandler)
        $script:recognizer.RecognizeAsync([System.Speech.Recognition.RecognizeMode]::Multiple)

        $script:recognitionActive = $true
        $listenButton.Text = 'MIC  Always listening'
        $listenButton.BackColor = [Drawing.Color]::FromArgb(42, 117, 78)
        $statusLabel.Text = "Listening in $($selectedRecognizer.Culture.Name): say a range number."
    }
    catch {
        $script:recognitionActive = $false
        if ($null -ne $script:recognizer) {
            try { $script:recognizer.Dispose() } catch {}
            $script:recognizer = $null
        }
        $listenButton.Text = 'MIC  Retry'
        $listenButton.BackColor = [Drawing.Color]::FromArgb(137, 64, 64)
        $statusLabel.Text = $_.Exception.Message
    }
}

function Invoke-SpokenRange {
    param([string]$NumberText, [string]$FullText)

    try {
        $range = Convert-SpokenRange $NumberText
        $selectedMode = if ($fastAimCheck.Checked) { 'fast' } else { 'minimum' }
        [void](Get-BallisticSolution -Range $range -RecommendationMode $selectedMode)
        $rangeBox.Text = $range.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)
        $script:wakeDeadline = [DateTime]::MinValue
        $script:includeRangeInNextAnswer = $true
        & $calculate
        $statusLabel.Text = "Heard: '$FullText' - ready for the next number or query."
    }
    catch {
        $script:wakeDeadline = [DateTime]::MinValue
        $statusLabel.Text = "Could not understand '$FullText': $($_.Exception.Message)"
        Speak-Text 'Number not understood.'
    }
}

function Process-RecognizedSpeech {
    param([string]$Text, [string]$DisplayText = $Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    $normalized = $Text.Trim().ToLowerInvariant()

    if ($normalized -match '^(please\s+)?repeat(?:\s+(that|last|answer))?$') {
        if ([string]::IsNullOrWhiteSpace($script:lastAnswer)) {
            $statusLabel.Text = 'Nothing to repeat yet.'
            Speak-Text 'No previous answer.'
        }
        else {
            $statusLabel.Text = "Repeating: $($script:lastAnswer)"
            Speak-Text $script:lastAnswer
        }
        return
    }

    if ($normalized -match '^(please\s+)?angle(?:\s+(again|only))?$') {
        if ([string]::IsNullOrWhiteSpace($script:lastAngleAnswer)) {
            $statusLabel.Text = 'No previous angle to repeat.'
            Speak-Text 'No previous answer.'
        }
        else {
            $statusLabel.Text = "Angle: $($script:lastAngleAnswer)"
            Speak-Text $script:lastAngleAnswer
        }
        return
    }

    if ($normalized -match '^(please\s+)?charges?(?:\s+(again|only))?$') {
        if ([string]::IsNullOrWhiteSpace($script:lastChargesAnswer)) {
            $statusLabel.Text = 'No previous charges to repeat.'
            Speak-Text 'No previous answer.'
        }
        else {
            $statusLabel.Text = "Charges: $($script:lastChargesAnswer)"
            Speak-Text $script:lastChargesAnswer
        }
        return
    }

    if ($normalized -match '^(please\s+)?(current|currant|corrent)(?:\s+(range|answer))?$' -or
        $normalized -match '^(please\s+)?distance(?:\s+(now|again))?$') {
        if ([string]::IsNullOrWhiteSpace($script:lastRangeAnswer)) {
            $statusLabel.Text = 'No current range yet.'
            Speak-Text 'No previous answer.'
        }
        else {
            $statusLabel.Text = "Current range: $($script:lastRangeAnswer) meters"
            Speak-Text $script:lastRangeAnswer
        }
        return
    }

    if (Test-RangeUtterance $normalized) {
        Invoke-SpokenRange -NumberText $normalized -FullText $DisplayText
    }
}

$listenerTimer = [Windows.Forms.Timer]::new()
$listenerTimer.Interval = 150
$listenerTimer.Add_Tick({
    $heard = [string]::Empty
    while ($script:speechQueue.TryDequeue([ref]$heard)) {
        if ($heard -match '^__RECOGNIZER_ENDED__:(\d+)$') {
            $endedGeneration = [int]$Matches[1]
            if ($endedGeneration -eq $script:recognizerGeneration -and
                $script:recognitionWanted -and -not $script:closing) {
                Stop-ContinuousListening -DisableRestart $false
                Start-ContinuousListening
            }
        }
        else {
            if ([DateTime]::UtcNow -gt $script:ignoreRecognitionUntil) {
                $separatorIndex = $heard.IndexOf([char]31)
                if ($separatorIndex -ge 0) {
                    $displayText = $heard.Substring(0, $separatorIndex)
                    $lexicalText = $heard.Substring($separatorIndex + 1)
                    if ([string]::IsNullOrWhiteSpace($lexicalText)) { $lexicalText = $displayText }
                    Process-RecognizedSpeech -Text $lexicalText -DisplayText $displayText
                }
                else {
                    Process-RecognizedSpeech $heard
                }
            }
        }
        $heard = [string]::Empty
    }
})
$listenerTimer.Start()

$listenButton.Add_Click({
    if ($script:recognitionActive) {
        Stop-ContinuousListening
        $statusLabel.Text = 'Continuous listening paused. Click MIC to resume.'
    }
    else {
        Start-ContinuousListening
    }
})

$form.Add_Shown({
    $rangeBox.Focus()
    Start-ContinuousListening
})
$form.Add_FormClosed({
    $script:closing = $true
    $script:recognitionWanted = $false
    $listenerTimer.Stop()
    Stop-ContinuousListening
    if ($null -ne $script:synthesizer) { $script:synthesizer.Dispose() }
    if ($null -ne $script:sapiVoice) {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($script:sapiVoice)
    }
})

[void]$form.ShowDialog()
