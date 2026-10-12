<#
  runner.ps1 - elevated job runner ("mailbox" pattern)
  ----------------------------------------------------
  Runs ONCE with admin rights (via the ArenaElev scheduled task created by
  enable-elev.ps1). Then stays alive and executes any *.ps1 that appears in:

      C:\Users\<user>\agent-bridge\elev\in\

  Each finished job leaves full output in  elev\out\<name>.out
  and an exit marker in                     elev\out\<name>.done  ("DONE <code>")
  Everything is written to the audit log    elev\elev.log

  Controls:
    pause/stop : create a file named STOP in the elev folder
                 (or: Stop-ScheduledTask -TaskName ArenaElev)
    status     : elev\hb.txt  = heartbeat unix time, elev\busy.txt = current job
#>

$ErrorActionPreference = 'Continue'

$base  = Join-Path $env:USERPROFILE 'agent-bridge\elev'
$inD   = Join-Path $base 'in'
$runD  = Join-Path $base 'run'
$outD  = Join-Path $base 'out'
$hb    = Join-Path $base 'hb.txt'
$busy  = Join-Path $base 'busy.txt'
$stopF = Join-Path $base 'STOP'
$logF  = Join-Path $base 'elev.log'

# ---- single instance guard (per session) ----
$mutex = $null
$gotLock = $false
try {
  $mutex = New-Object System.Threading.Mutex($false, 'Local\ArenaElevRunner')
  $gotLock = $mutex.WaitOne(0)
} catch { $gotLock = $true }   # if mutex API fails, do not block startup
if (-not $gotLock) { exit 0 }

foreach ($d in @($base, $inD, $runD, $outD)) {
  New-Item -ItemType Directory -Force -Path $d | Out-Null
}
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

# prefer PowerShell 7 for jobs (clean UTF-8 everywhere)
$jobExe = 'powershell.exe'
if (Test-Path "$env:ProgramFiles\PowerShell\7\pwsh.exe") {
  $jobExe = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
}

function Log([string]$m) {
  try { Add-Content -LiteralPath $logF -Value ((Get-Date).ToString('s') + '  ' + $m) -Encoding UTF8 } catch {}
}

Log ("runner up: pid=$PID exe=$jobExe user=$env:USERNAME")

# ---- light housekeeping: drop very old job artifacts (> 3 days) ----
try {
  $cut = (Get-Date).AddDays(-3)
  Get-ChildItem -LiteralPath $runD -File -EA SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cut } | Remove-Item -Force -EA SilentlyContinue
  Get-ChildItem -LiteralPath $outD -File -EA SilentlyContinue    | Where-Object { $_.LastWriteTime -lt $cut } | Remove-Item -Force -EA SilentlyContinue
} catch {}

while ($true) {
  try {
    Set-Content -LiteralPath $hb -Value ([DateTimeOffset]::Now.ToUnixTimeSeconds()) -Encoding Ascii -Force

    if (Test-Path -LiteralPath $stopF) {
      Remove-Item -LiteralPath $stopF -Force -EA SilentlyContinue
      Log 'stop file -> exiting'
      break
    }

    $jobs = @(Get-ChildItem -LiteralPath $inD -Filter '*.ps1' -File -EA SilentlyContinue | Sort-Object Name)

    foreach ($j in $jobs) {
      $outF  = Join-Path $outD ($j.Name + '.out')
      $doneF = Join-Path $outD ($j.Name + '.done')
      $runF  = Join-Path $runD $j.Name

      Remove-Item -LiteralPath $doneF -Force -EA SilentlyContinue
      $hdr = '=== job: ' + $j.Name + "`r`n=== started: " + (Get-Date).ToString('s') + '  user: ' + $env:USERNAME + '  pid: ' + $PID + "`r`n=== elevated: True`r`n`r`n"
      Set-Content -LiteralPath $outF -Value $hdr -Encoding UTF8

      Move-Item -LiteralPath $j.FullName -Destination $runF -Force -EA SilentlyContinue
      if (Test-Path -LiteralPath $j.FullName) {
        # could not take the job (locked or grabbed concurrently) -> skip this round
        Log ('skip (locked): ' + $j.Name)
        continue
      }

      Set-Content -LiteralPath $busy -Value $j.Name -Encoding Ascii -Force
      Log ('run  ' + $j.Name)

      $code = -1
      try {
        & $jobExe -NoProfile -ExecutionPolicy Bypass -File $runF *>> $outF
        $code = $LASTEXITCODE
      } catch {
        Add-Content -LiteralPath $outF -Value ("`r`n[runner] exec error: " + $_.Exception.Message) -Encoding UTF8
        $code = 9000
      }

      Set-Content -LiteralPath $doneF -Value ('DONE ' + $code) -Encoding Ascii -Force
      Remove-Item -LiteralPath $busy -Force -EA SilentlyContinue
      Log ('done ' + $j.Name + ' rc=' + $code)
    }
  } catch {
    Log ('loop error: ' + $_.Exception.Message)
  }
  Start-Sleep -Milliseconds 700
}
