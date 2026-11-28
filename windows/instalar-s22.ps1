<#
  Instala o "S22 microscópio" no nomad (Windows 11). Idempotente.
    - scrcpy pelo winget, se faltar
    - %LOCALAPPDATA%\s22\s22-microscopio.ps1 (cópia do arquivo ao lado deste)
    - atalho "S22 microscopio" no menu Iniciar, com Ctrl+Alt+M
  Uso:  pwsh -File instalar-s22.ps1            instala/atualiza
        pwsh -File instalar-s22.ps1 -Desfazer  remove o atalho e a cópia (o scrcpy fica)
  Variáveis só para testes: S22_DESTINO, S22_MENU, S22_SEM_WINGET=1, S22_SEM_ATALHO=1
#>
param([switch]$Desfazer)
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$destDir = if ($env:S22_DESTINO) { $env:S22_DESTINO } else { Join-Path $env:LOCALAPPDATA 's22' }
$menu = if ($env:S22_MENU) { $env:S22_MENU } else { Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs' }
$script = Join-Path $destDir 's22-microscopio.ps1'
$lnk = Join-Path $menu 'S22 microscopio.lnk'

if ($Desfazer) {
    Remove-Item -LiteralPath $lnk, $script -ErrorAction SilentlyContinue
    if ((Test-Path $destDir) -and -not (Get-ChildItem $destDir -Force)) { Remove-Item $destDir }
    Write-Host "removido: atalho e $script (o scrcpy continua instalado)"
    exit 0
}

if (-not $env:S22_SEM_WINGET) {
    if (Get-Command scrcpy -ErrorAction SilentlyContinue) { Write-Host "scrcpy já instalado" }
    else { winget install --id Genymobile.scrcpy -e --accept-source-agreements --accept-package-agreements }
}

New-Item -ItemType Directory -Force -Path $destDir | Out-Null
Copy-Item -LiteralPath (Join-Path $here 's22-microscopio.ps1') -Destination $script -Force
Write-Host "lançador: $script"

if (-not $env:S22_SEM_ATALHO) {
    $pw = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pw) { $pw = 'powershell.exe' }
    New-Item -ItemType Directory -Force -Path $menu | Out-Null
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    $s.TargetPath = $pw
    $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
    $s.Hotkey = 'CTRL+ALT+M'
    $s.Description = 'Camera traseira do S22 ao vivo (scrcpy)'
    $s.Save()
    Write-Host "atalho: $lnk (Ctrl+Alt+M)"
}
Write-Host ""
Write-Host "No S22, uma vez: Opções do desenvolvedor > Depuração USB ligada; plugue no nomad e aceite 'Permitir depuração USB'."
