# Battery Logger V17.4 — Battery Health Companion (Windows PowerShell 5.1)
# Read-only local monitor. Retrieves real design/full-charge capacity when the device/driver exposes it.
$ErrorActionPreference = 'SilentlyContinue'
$Port = 8765
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Dashboard = Join-Path $Root 'Battery_Logger.html'
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")

function Get-FirstValidNumber {
    param($Object, [string[]]$Names)
    if ($null -eq $Object) { return $null }
    foreach ($name in $Names) {
        $prop = $Object.PSObject.Properties[$name]
        if ($prop -and $null -ne $prop.Value) {
            try {
                $n = [double]$prop.Value
                if ($n -gt 0 -and $n -lt 1000000000) { return $n }
            } catch {}
        }
    }
    return $null
}

function Normalize-InstanceName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    # WMI classes may differ only by trailing instance counters.
    return (($Name.Trim().ToLowerInvariant() -replace '_\d+$','') -replace '\s+','')
}

function Get-ReportCapacities {
    $report = Join-Path $env:TEMP ("BatteryLogger-report-{0}.html" -f [guid]::NewGuid().ToString('N'))
    try {
        $proc = Start-Process -FilePath "$env:WINDIR\System32\powercfg.exe" `
            -ArgumentList @('/batteryreport','/output', $report) -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop
        if ($proc.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $report)) {
            return @{ Error = "powercfg /batteryreport failed (exit $($proc.ExitCode))." }
        }

        $html = [IO.File]::ReadAllText($report)
        $designValues = @()
        $fullValues = @()

        # Parse individual table rows first; this handles labels and values split across HTML cells.
        foreach ($match in [regex]::Matches($html, '(?is)<tr\b[^>]*>(.*?)</tr>')) {
            $rowHtml = $match.Groups[1].Value
            $rowText = [System.Net.WebUtility]::HtmlDecode([regex]::Replace($rowHtml, '(?is)<[^>]+>', ' '))
            $rowText = ($rowText -replace '[\u00A0\s]+',' ').Trim()
            if ($rowText -match '(?i)DESIGN\s+CAPACITY') {
                $after = [regex]::Match($rowText, '(?i)DESIGN\s+CAPACITY\s*:?\s*([0-9][0-9,\.]*)')
                if ($after.Success) {
                    $n = 0.0
                    if ([double]::TryParse(($after.Groups[1].Value -replace ',',''), [Globalization.NumberStyles]::Any, [Globalization.CultureInfo]::InvariantCulture, [ref]$n) -and $n -gt 0) { $designValues += $n }
                }
            }
            if ($rowText -match '(?i)FULL\s+CHARGE\s+CAPACITY') {
                $after = [regex]::Match($rowText, '(?i)FULL\s+CHARGE\s+CAPACITY\s*:?\s*([0-9][0-9,\.]*)')
                if ($after.Success) {
                    $n = 0.0
                    if ([double]::TryParse(($after.Groups[1].Value -replace ',',''), [Globalization.NumberStyles]::Any, [Globalization.CultureInfo]::InvariantCulture, [ref]$n) -and $n -gt 0) { $fullValues += $n }
                }
            }
        }

        # Fallback for report layouts where the capacity label and value are not in the same row.
        if ($designValues.Count -eq 0 -or $fullValues.Count -eq 0) {
            $plain = [System.Net.WebUtility]::HtmlDecode([regex]::Replace($html, '(?is)<(script|style)\b.*?</\1>', ' '))
            $plain = [regex]::Replace($plain, '(?i)<br\s*/?>|</t[dh]|</tr|</p|</div|</h[1-6]', ' ')
            $plain = [regex]::Replace($plain, '(?s)<[^>]+>', ' ')
            $plain = ($plain -replace '[\u00A0\s]+',' ')
            if ($designValues.Count -eq 0) {
                $m = [regex]::Match($plain, '(?i)DESIGN\s+CAPACITY\s*:?\s*([0-9][0-9,\.]*)\s*mWh')
                if ($m.Success) { $designValues += [double](($m.Groups[1].Value -replace ',','')) }
            }
            if ($fullValues.Count -eq 0) {
                $m = [regex]::Match($plain, '(?i)FULL\s+CHARGE\s+CAPACITY\s*:?\s*([0-9][0-9,\.]*)\s*mWh')
                if ($m.Success) { $fullValues += [double](($m.Groups[1].Value -replace ',','')) }
            }
        }

        if ($designValues.Count -gt 0 -and $fullValues.Count -gt 0) {
            # Use corresponding values where report lists multiple battery packs; otherwise use first pair.
            $idx = 0
            if ($designValues.Count -gt 1 -and $fullValues.Count -gt 1) {
                $idx = 0
                for ($i=0; $i -lt [Math]::Min($designValues.Count,$fullValues.Count); $i++) {
                    if ($designValues[$i] -gt 0 -and $fullValues[$i] -gt 0) { $idx=$i; break }
                }
            }
            $d = [double]$designValues[$idx]
            $f = [double]$fullValues[[Math]::Min($idx, $fullValues.Count - 1)]
            if ($d -gt 0 -and $f -gt 0 -and $f -le ($d * 2)) {
                return @{ Design=$d; Full=$f; Name='Installed battery'; Source='Windows battery report (powercfg)'; Error=$null }
            }
        }
        return @{ Error='Windows battery report was generated, but its capacity rows could not be parsed.' }
    } catch {
        return @{ Error=("Battery report fallback error: " + $_.Exception.Message) }
    } finally {
        Remove-Item -LiteralPath $report -Force -ErrorAction SilentlyContinue
    }
}

function Get-BatteryData {
    $design = $null; $full = $null; $source = $null; $batteryName = $null
    $message = 'Battery detected, but Windows did not expose valid design and full-charge capacity values.'
    $diagnostics = New-Object System.Collections.Generic.List[string]
    $pairs = @()

    # Preferred: Windows battery WMI classes. Pair by InstanceName rather than mixing packs.
    try {
        $staticItems = @(Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop)
        $fullItems = @(Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop)
        if ($staticItems.Count -gt 0) { $diagnostics.Add("BatteryStaticData: $($staticItems.Count)") } else { $diagnostics.Add('BatteryStaticData: no rows') }
        if ($fullItems.Count -gt 0) { $diagnostics.Add("BatteryFullChargedCapacity: $($fullItems.Count)") } else { $diagnostics.Add('BatteryFullChargedCapacity: no rows') }

        foreach ($s in $staticItems) {
            $d = Get-FirstValidNumber $s @('DesignedCapacity','DesignCapacity')
            if (-not $d) { continue }
            $instance = [string]$s.InstanceName
            $norm = Normalize-InstanceName $instance
            $fitem = $null
            if ($instance) {
                $fitem = $fullItems | Where-Object { [string]$_.InstanceName -eq $instance } | Select-Object -First 1
                if (-not $fitem) {
                    $fitem = $fullItems | Where-Object { (Normalize-InstanceName ([string]$_.InstanceName)) -eq $norm } | Select-Object -First 1
                }
            }
            if (-not $fitem -and $staticItems.Count -eq 1 -and $fullItems.Count -eq 1) { $fitem = $fullItems[0] }
            $f = Get-FirstValidNumber $fitem @('FullChargedCapacity','FullChargeCapacity')
            if ($d -gt 0 -and $f -gt 0 -and $f -le ($d * 2)) {
                $name = $instance
                if ($s.PSObject.Properties['DeviceName'] -and $s.DeviceName) { $name = [string]$s.DeviceName }
                $pairs += [pscustomobject]@{ Design=$d; Full=$f; Name=$name; Source='Windows Battery WMI' }
            }
        }
    } catch { $diagnostics.Add("Battery WMI error: $($_.Exception.Message)") }

    if ($pairs.Count -gt 0) {
        $best = $pairs | Sort-Object Design -Descending | Select-Object -First 1
        $design = [double]$best.Design; $full = [double]$best.Full
        $batteryName = [string]$best.Name; $source = [string]$best.Source
    }

    # Secondary source: Win32_Battery capacity fields (some drivers populate these).
    if (-not $design -or -not $full) {
        try {
            $legacy = @(Get-CimInstance -Namespace root\cimv2 -ClassName Win32_Battery -ErrorAction Stop)
            $diagnostics.Add("Win32_Battery rows: $($legacy.Count)")
            $valid = @()
            foreach ($b in $legacy) {
                $d = Get-FirstValidNumber $b @('DesignCapacity')
                $f = Get-FirstValidNumber $b @('FullChargeCapacity')
                if ($d -gt 0 -and $f -gt 0 -and $f -le ($d * 2)) {
                    $valid += [pscustomobject]@{ Design=$d; Full=$f; Name=[string]$b.Name; Source='Win32_Battery WMI' }
                }
            }
            if ($valid.Count -gt 0) {
                $best = $valid | Sort-Object Design -Descending | Select-Object -First 1
                $design = [double]$best.Design; $full = [double]$best.Full
                $batteryName = [string]$best.Name; $source = [string]$best.Source
            }
        } catch { $diagnostics.Add("Win32_Battery error: $($_.Exception.Message)") }
    }

    # Last automatic fallback: parse the Windows-generated battery report. Cached to avoid rerunning every poll.
    if (-not $design -or -not $full) {
        $reportData = Get-ReportCapacities
        if ($reportData -and $reportData.Design -gt 0 -and $reportData.Full -gt 0) {
            $design = [double]$reportData.Design; $full = [double]$reportData.Full
            $batteryName = [string]$reportData.Name; $source = [string]$reportData.Source
        } elseif ($reportData.Error) {
            $diagnostics.Add([string]$reportData.Error)
        }
    }

    $health = $null; $wear = $null
    if ($design -gt 0 -and $full -gt 0 -and $full -le ($design * 2)) {
        $health = [math]::Round([math]::Min(100, ($full / $design) * 100), 1)
        $wear = [math]::Round([math]::Max(0, (1 - ($full / $design)) * 100), 1)
        $message = 'Health = full-charge capacity ÷ design capacity × 100. This is a capacity-based estimate, not a battery safety certification.'
    } else {
        try {
            $present = @(Get-CimInstance -Namespace root\cimv2 -ClassName Win32_Battery -ErrorAction Stop)
            if ($present.Count -eq 0) {
                $message = 'Windows did not detect a battery. Check the battery connection and ACPI/battery driver.'
            } else {
                $message = 'Battery detected, but no usable design/full-charge capacity pair was returned. Check the Diagnostics endpoint or Windows battery report; this laptop/driver may not expose battery-health telemetry.'
            }
        } catch {}
    }

    return @{
        designCapacityMWh = $(if($design){[math]::Round($design,0)}else{$null})
        fullChargeMWh = $(if($full){[math]::Round($full,0)}else{$null})
        batteryHealthPercent = $health
        wearPercent = $wear
        batteryName = $batteryName
        batterySource = $source
        batteryMessage = $message
        diagnostics = @($diagnostics.ToArray())
    }
}

# Cache capacity reads for 45 seconds; avoids running powercfg repeatedly while UI polls.
$script:CachedBattery = $null
$script:CacheTime = [datetime]::MinValue
function Get-Status {
    if (-not $script:CachedBattery -or ((Get-Date) - $script:CacheTime).TotalSeconds -ge 45) {
        $script:CachedBattery = Get-BatteryData
        $script:CacheTime = Get-Date
    }
    $result = @{}
    foreach ($k in $script:CachedBattery.Keys) { $result[$k] = $script:CachedBattery[$k] }
    $result['timestamp'] = (Get-Date).ToString('o')
    try {
        $bat = @(Get-CimInstance -Namespace root\cimv2 -ClassName Win32_Battery)
        if ($bat.Count -gt 0) {
            $result['chargePercent'] = $bat[0].EstimatedChargeRemaining
            $result['batteryStatusCode'] = $bat[0].BatteryStatus
        }
    } catch {}
    return $result
}

try {
    $listener.Start()
} catch {
    # Companion is launched hidden; write a diagnostic file for troubleshooting.
    $errPath = Join-Path $Root 'BatteryLogger-StartupError.txt'
    [IO.File]::WriteAllText($errPath, ("Could not start local companion on port {0}: {1}" -f $Port,$_.Exception.Message), [Text.Encoding]::UTF8)
    exit 1
}

while ($listener.IsListening) {
    $ctx = $null
    try {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $res = $ctx.Response
        $path = $req.Url.AbsolutePath
        $res.Headers.Add('Cache-Control','no-store')
        if ($path -eq '/api/status' -or $path -eq '/api/diagnostics') {
            $status = Get-Status
            if ($path -eq '/api/diagnostics') {
                $status['runtime'] = "Windows PowerShell $($PSVersionTable.PSVersion)"
                $status['reportPath'] = 'A temporary powercfg report is created and deleted automatically when needed.'
            }
            $json = ($status | ConvertTo-Json -Compress -Depth 6)
            $bytes = [Text.Encoding]::UTF8.GetBytes($json)
            $res.ContentType = 'application/json; charset=utf-8'
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes,0,$bytes.Length)
        } elseif ($path -eq '/' -or $path -eq '/Battery_Logger.html') {
            if (Test-Path -LiteralPath $Dashboard) {
                $bytes = [IO.File]::ReadAllBytes($Dashboard)
                $res.ContentType = 'text/html; charset=utf-8'
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes,0,$bytes.Length)
            } else {
                $res.StatusCode = 404
                $bytes = [Text.Encoding]::UTF8.GetBytes('Battery_Logger.html was not found beside the companion.')
                $res.ContentType = 'text/plain; charset=utf-8'
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes,0,$bytes.Length)
            }
        } else { $res.StatusCode = 404 }
        $res.Close()
    } catch {
        if ($ctx -and $ctx.Response) { try { $ctx.Response.Close() } catch {} }
    }
}
