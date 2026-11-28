# Tests for windows/s22-microscopio.ps1 and windows/instalar-s22.ps1 with fake scrcpy/adb.
# Runs in pwsh 7 (Linux or Windows): pwsh -NoProfile -File windows/tests/test_s22_microscopio.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path $here '..' 's22-microscopio.ps1'
$inst = Join-Path $here '..' 'instalar-s22.ps1'
$T = Join-Path ([IO.Path]::GetTempPath()) ("s22-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $T | Out-Null
$calls = Join-Path $T 'calls'
$script:fail = 0; $script:n = 0
function ok($name, [scriptblock]$cond) {
    $script:n++
    if (& $cond) { Write-Host "ok   $name" } else { Write-Host "FAIL $name"; $script:fail++ }
}
$isWin = $IsWindows -or ($PSVersionTable.PSEdition -eq 'Desktop')
$pw = (Get-Process -Id $PID).Path

# fake scrcpy: --help prints FAKE_HELP (or a modern help); otherwise records argv + the adb env it saw
$fakeScrcpy = Join-Path $T 'fakescrcpy.ps1'
@'
if ($args -contains '--help') {
    if ($env:FAKE_HELP) { Write-Output $env:FAKE_HELP } else { Write-Output "--video-source --camera-zoom --camera-torch --camera-ar" }
    exit 0
}
Add-Content -Path $env:CALLS -Value ("scrcpy port=" + $env:ANDROID_ADB_SERVER_PORT + " " + ($args -join ' '))
if ($env:FAKE_RC) { exit [int]$env:FAKE_RC } else { exit 0 }
'@ | Set-Content -Path $fakeScrcpy
$fakeAdb = Join-Path $T 'fakeadb.ps1'
'Add-Content -Path $env:CALLS -Value ("adb " + ($args -join " ")); exit 0' | Set-Content -Path $fakeAdb
if ($isWin) {
    foreach ($fake in 'fscrcpy', 'fadb') {
        $target = if ($fake -eq 'fscrcpy') { $fakeScrcpy } else { $fakeAdb }
        Set-Content "$T\$fake.cmd" "@`"$pw`" -NoProfile -File `"$target`" %*`r`n@exit /b %ERRORLEVEL%"
    }
} else {
    # plain sh fakes: a PowerShell fake would itself parse "--tcpip=host:port" as -name:value (a real .exe never does)
    @'
#!/bin/sh
case " $* " in *" --help "*) if [ -n "$FAKE_HELP" ]; then echo "$FAKE_HELP"; else echo "--video-source --camera-zoom --camera-torch --camera-ar"; fi; exit 0 ;; esac
echo "scrcpy port=$ANDROID_ADB_SERVER_PORT $*" >> "$CALLS"
exit ${FAKE_RC:-0}
'@ | Set-Content "$T/fscrcpy"
    @'
#!/bin/sh
echo "adb $*" >> "$CALLS"
'@ | Set-Content "$T/fadb"
    chmod +x "$T/fscrcpy" "$T/fadb"
}
$ext = if ($isWin) { '.cmd' } else { '' }
$env:CALLS = $calls
$env:S22_SCRCPY = Join-Path $T "fscrcpy$ext"
$env:S22_ADB = Join-Path $T "fadb$ext"

function Run([string[]]$a) {
    Set-Content -Path $calls -Value $null
    & $pw -NoProfile -File $script @a *> (Join-Path $T 'out')
    return $LASTEXITCODE
}
function Calls { @(Get-Content $calls | Where-Object { $_ }) }
function Out { (Get-Content (Join-Path $T 'out')) -join "`n" }

$env:ANDROID_ADB_SERVER_PORT = '15037'     # left over from the S10 launcher: must not leak into the S22 run
$rc = Run @()
$c = @(Calls)
ok 'USB default: back camera, sensor ratio, no audio, select-usb; local adb (no inherited port)' { $rc -eq 0 -and $c.Count -eq 1 -and $c[0] -eq 'scrcpy port= --video-source=camera --camera-facing=back --camera-ar=sensor --no-audio --window-title=S22 microscopio --select-usb' }
Remove-Item Env:ANDROID_ADB_SERVER_PORT

$rc = Run @('-Zoom', '2.5', '-Lanterna', '-Gravar', '/tmp/a.mp4')
ok 'zoom (dot decimal), torch and record' { $rc -eq 0 -and @(Calls)[0] -like '*--camera-zoom=2.5 --camera-torch --record=/tmp/a.mp4 --select-usb' }

$rc = Run @('-SemFio', '192.0.2.50:41234')
ok 'wireless: --tcpip with the address, no select-usb' { $rc -eq 0 -and @(Calls)[0] -like '*--tcpip=192.0.2.50:41234' -and @(Calls)[0] -notlike '*select-usb*' }

$rc = Run @('-Serial', 'R5CT123ABC')
ok 'serial chosen' { @(Calls)[0] -like '*--serial=R5CT123ABC' }

$rc = Run @('-Parear', '192.0.2.50:37000')
ok 'pairing runs adb pair, no scrcpy' { $rc -eq 0 -and @(Calls)[0] -eq 'adb pair 192.0.2.50:37000' -and @(Calls).Count -eq 1 }

foreach ($bad in @(@('-SemFio', 'x;calc'), @('-Parear', '1.2.3.4'), @('-Serial', 'a b'), @('-Zoom', '0.5'), @('-Zoom', '99'))) {
    $rc = Run $bad
    ok "refused: $($bad -join ' ')" { $rc -eq 2 -and @(Calls).Count -eq 0 }
}

$env:FAKE_HELP = '--video-source --camera-ar'
$rc = Run @('-Zoom', '2', '-Lanterna')
ok 'older scrcpy without zoom/torch: runs without them and warns' { $rc -eq 0 -and @(Calls)[0] -notlike '*camera-zoom*' -and @(Calls)[0] -notlike '*camera-torch*' -and (Out) -match 'Alt\+seta' }
$env:FAKE_HELP = '--max-size only'
$rc = Run @()
ok 'scrcpy without camera support: clear message, nothing run' { $rc -ne 0 -and @(Calls).Count -eq 0 -and (Out) -match 'winget upgrade' }
Remove-Item Env:FAKE_HELP

$env:FAKE_RC = '1'
$rc = Run @()
ok 'USB failure explains debugging/cable' { $rc -eq 1 -and (Out) -match 'Depura..o USB' }
$rc = Run @('-SemFio', '192.0.2.50:41234')
ok 'wireless failure points to -Parear' { $rc -eq 1 -and (Out) -match '-Parear' }
Remove-Item Env:FAKE_RC

$env:S22_SCRCPY = Join-Path $T 'nao-existe'
$rc = Run @()
ok 'no scrcpy -> install hint' { $rc -eq 1 -and (Out) -match 'winget install Genymobile.scrcpy' }

# installer (no winget, no COM shortcut off Windows)
$env:S22_DESTINO = Join-Path $T 'dest'; $env:S22_MENU = Join-Path $T 'menu'; $env:S22_SEM_WINGET = '1'
if (-not $isWin) { $env:S22_SEM_ATALHO = '1' }
& $pw -NoProfile -File $inst *> (Join-Path $T 'out'); $rc = $LASTEXITCODE
ok 'installer copies the launcher byte for byte' { $rc -eq 0 -and ((Get-FileHash $script).Hash -eq (Get-FileHash (Join-Path $env:S22_DESTINO 's22-microscopio.ps1')).Hash) }
& $pw -NoProfile -File $inst *> $null; $rc = $LASTEXITCODE
ok 'installer is idempotent' { $rc -eq 0 }
& $pw -NoProfile -File $inst -Desfazer *> $null; $rc = $LASTEXITCODE
ok 'undo removes the copy and the empty folder' { $rc -eq 0 -and -not (Test-Path $env:S22_DESTINO) }

Remove-Item -Recurse -Force $T
Write-Host "--- $($script:n) checks, $($script:fail) failed"
if ($script:fail -ne 0) { exit 1 }
