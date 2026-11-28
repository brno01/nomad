<#
  S22 como "microscópio" no nomad: a câmera traseira do Galaxy S22 ao vivo numa janela do Windows (scrcpy).
  Ao vivo na janela: Alt+↑ / Alt+↓ = zoom, Alt+T / Alt+Shift+T = lanterna liga/desliga.

  Uso:
    s22-microscopio                          cabo USB (padrão)
    s22-microscopio -Zoom 2 -Lanterna        começa com zoom 2x e a lanterna acesa
    s22-microscopio -Gravar C:\x\amostra.mp4 grava o vídeo enquanto mostra
    s22-microscopio -SemFio 192.0.2.50:41234      depuração sem fio (endereço e porta mostrados no S22)
    s22-microscopio -Parear 192.0.2.50:37000      pareia a depuração sem fio uma vez (pede o código de 6 dígitos)
    s22-microscopio -Serial <serial>         escolhe o aparelho quando há mais de um no USB

  O S22/S22+ não tem lente macro (foco mínimo de uns 10 cm): o zoom é digital. Para aumento de verdade, use uma
  lente de clipe. Usa o adb local do Windows (o do scrcpy), sem nada do atheron.
  Variáveis só para testes: S22_SCRCPY, S22_ADB.
#>
param(
    [double]$Zoom = 1.0,
    [switch]$Lanterna,
    [string]$Gravar = '',
    [string]$SemFio = '',
    [string]$Parear = '',
    [string]$Serial = ''
)
$ErrorActionPreference = 'Stop'

# the local adb server (port 5037): never a tunnel port inherited from another launcher (s10-tela uses 15037)
Remove-Item Env:ANDROID_ADB_SERVER_PORT -ErrorAction SilentlyContinue
Remove-Item Env:ADB_SERVER_SOCKET -ErrorAction SilentlyContinue

$Scrcpy = if ($env:S22_SCRCPY) { $env:S22_SCRCPY } else { 'scrcpy' }
$cmd = Get-Command $Scrcpy -ErrorAction SilentlyContinue
if (-not $cmd) {
    Write-Host "scrcpy não encontrado. Instale: winget install Genymobile.scrcpy (ou rode o instalar-s22.ps1)"
    exit 1
}

function Find-Adb {
    if ($env:S22_ADB) { return $env:S22_ADB }
    # winget puts a link to scrcpy.exe in its Links folder; the adb.exe it ships sits next to the real file
    $src = $cmd.Source
    try { $t = (Get-Item $src).Target; if ($t) { $src = @($t)[0] } } catch {}
    $nextTo = Join-Path (Split-Path -Parent $src) 'adb.exe'
    if (Test-Path $nextTo) { return $nextTo }
    if (Get-Command adb -ErrorAction SilentlyContinue) { return 'adb' }
    return $null
}
$Adb = Find-Adb

$hostPort = '^[A-Za-z0-9.-]{1,253}:\d{1,5}$'
if ($Parear) {
    if ($Parear -notmatch $hostPort) { Write-Host "-Parear espera ip:porta (o da tela 'Parear com código' do S22)"; exit 2 }
    if (-not $Adb) { Write-Host "adb não encontrado ao lado do scrcpy"; exit 1 }
    Write-Host "No S22: Opções do desenvolvedor > Depuração sem fio > Parear o dispositivo com código de pareamento."
    & $Adb pair $Parear      # adb asks for the 6-digit code itself
    exit $LASTEXITCODE
}
if ($SemFio -and $SemFio -notmatch $hostPort) { Write-Host "-SemFio espera ip:porta (o da tela 'Depuração sem fio' do S22)"; exit 2 }
if ($Serial -and $Serial -notmatch '^[A-Za-z0-9._:-]{1,64}$') { Write-Host "serial inválido"; exit 2 }
if ($Zoom -lt 1 -or $Zoom -gt 30) { Write-Host "-Zoom entre 1 e 30"; exit 2 }

$help = (& $Scrcpy --help 2>&1) -join "`n"
if ($help -notmatch '--video-source') {
    Write-Host "este scrcpy é antigo demais para espelhar a câmera; atualize: winget upgrade Genymobile.scrcpy"
    exit 1
}
$scArgs = @('--video-source=camera', '--camera-facing=back', '--camera-ar=sensor', '--no-audio',
    '--window-title=S22 microscopio')
if ($Zoom -ne 1.0) {
    if ($help -match '--camera-zoom') { $scArgs += "--camera-zoom=$([string]::Format([cultureinfo]::InvariantCulture, '{0}', $Zoom))" }
    else { Write-Host "aviso: este scrcpy não tem --camera-zoom; use Alt+seta para cima na janela" }
}
if ($Lanterna) {
    if ($help -match '--camera-torch') { $scArgs += '--camera-torch' }
    else { Write-Host "aviso: este scrcpy não tem --camera-torch" }
}
if ($Gravar) { $scArgs += "--record=$Gravar" }
if ($SemFio) {
    $scArgs += "--tcpip=$SemFio"
} elseif ($Serial) {
    $scArgs += "--serial=$Serial"
} else {
    $scArgs += '--select-usb'
}

& $Scrcpy @scArgs
$rc = $LASTEXITCODE
if ($rc -ne 0) {
    if ($SemFio) {
        Write-Host "não abriu pelo sem fio. Confira no S22 se a Depuração sem fio está ligada e se o endereço mudou; na 1ª vez, rode com -Parear."
    } else {
        Write-Host "não abriu pelo USB. Confira o cabo, a Depuração USB ligada no S22 e o aviso 'Permitir depuração USB' na tela dele."
    }
}
exit $rc
