# Short commands for this repo, so the long ones don't have to be retyped.
#
# Dot-sourced from $PROFILE.CurrentUserAllHosts
# (~\Documents\WindowsPowerShell\profile.ps1), so every new PowerShell -- the
# VS Code integrated terminal included -- has these available. Run `dev` for
# the list.
#
# Paths are derived from $PSScriptRoot, not hardcoded, so moving or renaming the
# checkout doesn't break anything (only the one `. path` line in the profile).

$Global:LiRepo    = $PSScriptRoot
$Global:LiDjango  = Join-Path $PSScriptRoot 'transcoapps'
$Global:LiBackend = Join-Path $PSScriptRoot 'transcoapps\Aptransco_TIS-main\aptransco_backend'
$Global:LiMobile  = Join-Path $PSScriptRoot 'transcoapps\Aptransco_TIS-main\drone_inspection_app'
$Global:LiVenvPy  = Join-Path $PSScriptRoot 'transcoapps\.venv\Scripts\python.exe'
$Global:LiNgrokDomain = 'mammal-calamari-create.ngrok-free.dev'


# --- where am I -------------------------------------------------------------

function root    { Set-Location $Global:LiRepo }
function proj    { Set-Location $Global:LiDjango }   # the live Django project
function backend { Set-Location $Global:LiBackend }  # Aptransco_TIS-main copy
function mobile  { Set-Location $Global:LiMobile }   # Flutter app


# --- Django -----------------------------------------------------------------

function Get-LiDjangoCommand {
    <#
      Names offered when tab-completing `dj <TAB>`: the handful of Django
      built-ins actually used here, plus every management command found on disk
      under line_inspection -- so a newly added command shows up in completion
      without editing this file.
    #>
    $builtin = @(
        'changepassword', 'check', 'collectstatic', 'createsuperuser', 'dbshell',
        'dumpdata', 'flush', 'loaddata', 'makemigrations', 'migrate', 'shell',
        'showmigrations', 'sqlmigrate', 'startapp', 'test'
    )
    $custom = @()
    $cmdDir = Join-Path $Global:LiDjango 'line_inspection\management\commands'
    if (Test-Path $cmdDir) {
        $custom = Get-ChildItem $cmdDir -Filter '*.py' |
            Where-Object { $_.Name -ne '__init__.py' } |
            ForEach-Object { $_.BaseName }
    }
    ($builtin + $custom + 'runserver') | Sort-Object -Unique
}

function dj {
    <#
      manage.py, run with the repo's own .venv python and from the project
      directory -- so it works from anywhere and never picks up the global
      Python 3.13 on PATH. Everything after the command name is passed through
      untouched, including --flags:  dj migrate --noinput
    #>
    param(
        [Parameter(Position = 0)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete)
            Get-LiDjangoCommand | Where-Object { $_ -like "$wordToComplete*" }
        })]
        [string] $Command
    )

    if (-not (Test-Path $Global:LiVenvPy)) {
        Write-Warning "venv python not found at $Global:LiVenvPy -- create it with: python -m venv $Global:LiDjango\.venv"
        return
    }
    if (-not $Command) { $Command = 'help' }

    Push-Location $Global:LiDjango
    try { & $Global:LiVenvPy 'manage.py' $Command @args }
    finally { Pop-Location }
}

function server {
    <#
      The dev server. Default binds localhost only; -Lan binds 0.0.0.0 so a
      phone running drone_inspection_app on the same Wi-Fi/hotspot can reach it
      (settings.py already allows the hotspot gateway and reads
      EXTRA_ALLOWED_HOSTS from .env.local for other addresses).
    #>
    param(
        [int]    $Port = 8000,
        [switch] $Lan
    )
    if ($Lan) {
        Get-NetIPAddress -AddressFamily IPv4 |
            Where-Object { $_.PrefixOrigin -ne 'WellKnown' -and $_.IPAddress -ne '127.0.0.1' } |
            ForEach-Object { Write-Host "  http://$($_.IPAddress):$Port/" -ForegroundColor DarkGray }
        dj runserver "0.0.0.0:$Port"
    } else {
        dj runserver $Port
    }
}

function migrate   { dj migrate @args }
function mkmig     { dj makemigrations @args }
function showmig   { dj showmigrations @args }
function dshell    { dj shell @args }
function dtest     { dj test @args }
function dcheck    { dj check @args }
function superuser { dj createsuperuser @args }

function venv {
    # Only needed for `pip install` and friends; `dj` already uses the venv.
    $activate = Join-Path $Global:LiDjango '.venv\Scripts\Activate.ps1'
    if (Test-Path $activate) { . $activate } else { Write-Warning "not found: $activate" }
}


# --- tunnel -----------------------------------------------------------------

function tunnel {
    # Reserved static domain, so the app's baked-in URL keeps working across
    # restarts. Point this at whatever port `server` is on.
    param([int] $Port = 8000)
    ngrok http "--domain=$Global:LiNgrokDomain" $Port
}


# --- Flutter ----------------------------------------------------------------

function app {
    param([string] $Device)
    Push-Location $Global:LiMobile
    try {
        if ($Device) { flutter run -d $Device @args } else { flutter run @args }
    } finally { Pop-Location }
}

function apk {
    Push-Location $Global:LiMobile
    try { flutter build apk --release @args } finally { Pop-Location }
}

function pubget {
    Push-Location $Global:LiMobile
    try { flutter pub get @args } finally { Pop-Location }
}

function devices { flutter devices }


# --- the cheat sheet --------------------------------------------------------

function dev {
    $rows = [ordered]@{
        'root / proj / backend / mobile' = 'cd to repo root / Django project / TIS backend / Flutter app'
        'server [-Lan] [-Port n]'        = 'manage.py runserver (default 8000; -Lan binds 0.0.0.0 for the phone)'
        'dj <TAB>'                       = 'any manage.py command, tab-completes (incl. this repo''s custom ones)'
        'migrate / mkmig / showmig'      = 'migrate / makemigrations / showmigrations'
        'dshell / dtest / dcheck'        = 'manage.py shell / test / check'
        'superuser'                      = 'createsuperuser'
        'venv'                           = 'activate .venv (only needed for pip)'
        'tunnel [-Port n]'               = "ngrok on the reserved domain $Global:LiNgrokDomain"
        'app [device] / apk / pubget'    = 'flutter run / build apk --release / pub get'
        'devices'                        = 'flutter devices'
        'dev'                            = 'this list'
    }
    Write-Host ''
    Write-Host '  line_inspection shortcuts' -ForegroundColor Cyan
    Write-Host ''
    foreach ($k in $rows.Keys) {
        Write-Host ('  {0,-31}' -f $k) -ForegroundColor Yellow -NoNewline
        Write-Host $rows[$k] -ForegroundColor Gray
    }
    Write-Host ''
    Write-Host '  Start typing any command and PSReadLine suggests the rest from history.' -ForegroundColor DarkGray
    Write-Host '  Tab = menu of completions   Up/Down = history filtered by what you typed   F2 = inline/list view' -ForegroundColor DarkGray
    Write-Host ''
}
