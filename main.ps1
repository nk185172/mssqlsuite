param (
    [ValidateSet("sqlclient", "sqlpackage", "sqlengine", "localdb")]
    [string[]]$Install  = $(if ($env:MSSQL_INSTALL) { ($env:MSSQL_INSTALL -split ',').Trim() | Where-Object { $_ } } else { @('sqlengine') }),
    [string]$SaPassword = ($env:SA_PASSWORD   ?? ''),
    [string]$ShowLog    = ($env:MSSQL_SHOW_LOG ?? 'false'),
    [string]$Collation  = ($env:MSSQL_COLLATION ?? 'SQL_Latin1_General_CP1_CI_AS'),
    [ValidateSet("2022", "2019", "2017")]
    [string]$Version    = ($env:MSSQL_VERSION  ?? '2019'),
    [string]$Path       = (@($env:MSSQL_DOWNLOAD_PATH, $env:RUNNER_TEMP, (Join-Path ([System.IO.Path]::GetTempPath()) 'mssql')) | Where-Object { $_ } | Select-Object -First 1)
)

# Mask the SA password immediately so it never appears in plain text in logs.
if ($SaPassword) { Write-Output "::add-mask::$SaPassword" }

# Convert once here so every function uses a clean bool rather than string comparisons.
$showLog = $ShowLog -eq 'true'

$totalTimer = [System.Diagnostics.Stopwatch]::StartNew()

function Write-Timing {
    param([string]$Label, [System.Diagnostics.Stopwatch]$Timer)
    $elapsed = $Timer.Elapsed.ToString('mm\:ss\.ff')
    Write-Output "::group::Timing: $Label completed in $elapsed"
    Write-Output "::endgroup::"
}

function Write-DockerLog {
    docker ps -a
    docker logs -t sql
}

# Runs the SQL Server docker container, waits for it to be ready, and optionally prints logs.
# ExtraArgs allows platform-specific flags (e.g. --memory=2g on macOS).
function Start-DockerSqlContainer {
    param([string[]]$ExtraArgs = @())
    $dockerArgs = @(
        'run',
        '-e', "ACCEPT_EULA=Y",
        '-e', "SA_PASSWORD=$SaPassword",
        '-e', "MSSQL_COLLATION=$Collation",
        '--name', 'sql',
        '-p', '1433:1433'
    ) + $ExtraArgs + @('-d', "mcr.microsoft.com/mssql/server:$Version-latest")

    docker @dockerArgs
    if ($LASTEXITCODE -ne 0) { throw "Failed to start SQL Server container (exit code $LASTEXITCODE)" }
    Wait-SqlServer
    if ($showLog) { Write-DockerLog }
}

# Polls TCP port 1433 until SQL Server accepts connections or times out.
# Avoids fixed sleeps that are either too short (flaky) or too long (slow).
function Wait-SqlServer {
    param([string]$HostName = "localhost", [int]$Port = 1433, [int]$TimeoutSeconds = 60)
    Write-Output "Waiting for SQL Server at ${HostName}:${Port}..."
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $tcp = [System.Net.Sockets.TcpClient]::new($HostName, $Port)
            $tcp.Dispose()
            Write-Output "SQL Server is accepting connections"
            return
        } catch {
            Start-Sleep -Seconds 1
        }
    } while ((Get-Date) -lt $deadline)
    throw "SQL Server at ${HostName}:${Port} did not become available within $TimeoutSeconds seconds"
}

function Install-SqlEngine {
    $ErrorActionPreference = 'Stop'
    Write-Output "Installing SQL Engine"

    if ($ismacos) {
        Write-Output "macOS detected, installing Docker then pulling SQL Server container"
        brew install docker
        colima start --runtime docker
        Start-DockerSqlContainer -ExtraArgs '--memory=2g'
        Write-Output "SQL Engine installed at localhost"
    }

    if ($islinux) {
        Write-Output "Linux detected, pulling SQL Server docker container"
        Start-DockerSqlContainer
        Write-Output "SQL Server container running at localhost"
    }

    if ($iswindows) {
        $versionConfig = @{
            "2017" = @{ Options = "";                            Major = 14 }
            "2019" = @{ Options = "/USESQLRECOMMENDEDMEMORYLIMITS"; Major = 15 }
            "2022" = @{ Options = "/USESQLRECOMMENDEDMEMORYLIMITS"; Major = 16 }
        }
        $installOptions = $versionConfig[$Version].Options
        $versionMajor   = $versionConfig[$Version].Major

        Push-Location $Path
        try {
            $setupDir = Join-Path $Path 'setup'
            $setup = Get-Item -Path (Join-Path $setupDir 'setup.exe') -ErrorAction Ignore

            # Use cached extracted setup if available; otherwise download and extract
            if ($null -eq $setup) {
                . (Join-Path $PSScriptRoot 'download.ps1') -Path $Path -Version $Version
                Start-Process -Wait -FilePath (Join-Path $Path 'sqlsetup.exe') -ArgumentList /qs, "/x:$setupDir"
                $setup = Get-Item -Path (Join-Path $setupDir 'setup.exe') -ErrorAction Ignore
            } else {
                Write-Output "Using cached extracted setup at $setupDir"
            }
            Write-Output "SQL Server setup path: $setup"

            if ($null -ne $setup) {
                # Pass /SECURITYMODE=SQL and /SAPWD during install to enable mixed auth
                # immediately, avoiding a post-install service restart.
                & $setup /q /ACTION=Install /INSTANCENAME=MSSQLSERVER /ASSYSADMINACCOUNTS='BUILTIN\ADMINISTRATORS' /FEATURES='SQLENGINE,FULLTEXT' /FILESTREAMLEVEL=3 /UPDATEENABLED=0 /FILESTREAMSHARENAME=MSSQLSERVER /SQLSVCACCOUNT='NT SERVICE\MSSQLSERVER' /SQLSYSADMINACCOUNTS='BUILTIN\ADMINISTRATORS' /TCPENABLED=1 /NPENABLED=0 /IACCEPTSQLSERVERLICENSETERMS /SQLCOLLATION=$Collation /SECURITYMODE=SQL /SAPWD="$SaPassword" $installOptions

                Wait-SqlServer
                # SA login is already enabled via /SECURITYMODE=SQL; just ensure it's active
                sqlcmd -S localhost -U sa -P "$SaPassword" -Q "ALTER LOGIN [sa] ENABLE;"

                Write-Output "SQL Server $Version installed at localhost (Windows and SQL auth enabled)"
            } else {
                throw "setup.exe not found"
            }
        } finally {
            Pop-Location
        }
    }
}

function Install-SqlClient {
    $ErrorActionPreference = 'Stop'
    if ($ismacos) {
        Write-Output "Installing sqlclient tools"
        brew tap microsoft/mssql-release https://github.com/Microsoft/homebrew-mssql-release
        #$null = brew update
        $log = brew install microsoft/mssql-release/msodbcsql17 microsoft/mssql-release/mssql-tools
        if ($LASTEXITCODE -ne 0) { throw "Failed to install sqlclient tools (exit code $LASTEXITCODE)" }
        if ($showLog) { $log }
    }
    Write-Output "sqlclient tools installed"
}

function Install-SqlPackage {
    $ErrorActionPreference = 'Stop'
    Write-Output "Installing sqlpackage"

    if ($ismacos -or $islinux) {
        # Skip download/extract if already cached
        if (Test-Path "$HOME/sqlpackage/sqlpackage") {
            Write-Output "sqlpackage found in cache, creating symlink only"
            if ($islinux -or $ismacos) { sudo ln -sf $HOME/sqlpackage/sqlpackage /usr/local/bin }
        } else {
            $url = if ($ismacos) { "https://aka.ms/sqlpackage-macos" } else { "https://aka.ms/sqlpackage-linux" }
            curl $url -4 -sL -o '/tmp/sqlpackage.zip'
            if ($LASTEXITCODE -ne 0) { throw "Failed to download sqlpackage from $url (exit code $LASTEXITCODE)" }
            $log = unzip /tmp/sqlpackage.zip -d $HOME/sqlpackage
            if ($LASTEXITCODE -ne 0) { throw "Failed to extract sqlpackage (exit code $LASTEXITCODE)" }
            chmod +x $HOME/sqlpackage/sqlpackage
            sudo ln -sf $HOME/sqlpackage/sqlpackage /usr/local/bin
            if ($showLog) {
                $log
                sqlpackage /version
            }
        }
    }

    if ($iswindows) {
        $log = choco install sqlpackage -y
        if ($showLog) {
            $log
            sqlpackage /version
        }
    }

    Write-Output "sqlpackage installed"
}

function Install-LocalDb {
    $ErrorActionPreference = 'Stop'
    if (-not $iswindows) {
        Write-Output "LocalDB can only be installed on Windows"
        return
    }

    if ($Version -eq "2022") {
        Write-Output "LocalDB for SQL Server 2022 is not yet available"
        return
    }

    # The windows-latest runner ships with SqlLocalDB pre-installed.
    # Only install via Chocolatey if it is not already present.
    $localDbExe = Get-Command SqlLocalDB -ErrorAction Ignore
    if ($null -eq $localDbExe) {
        Write-Output "SqlLocalDB not found, installing via Chocolatey"
        choco install sqllocaldb -y
        if ($LASTEXITCODE -ne 0) { throw "SqlLocalDB installation failed (exit code $LASTEXITCODE)" }
    } else {
        Write-Output "SqlLocalDB already present at $($localDbExe.Source)"
    }

    Write-Output "Verifying installation"
    sqlcmd -S "(localdb)\MSSQLLocalDB" -Q "SELECT @@VERSION;"
    if ($LASTEXITCODE -ne 0) { throw "SqlLocalDB verification failed (exit code $LASTEXITCODE)" }
    sqlcmd -S "(localdb)\MSSQLLocalDB" -Q "ALTER LOGIN [sa] WITH PASSWORD=N'$SaPassword'"
    sqlcmd -S "(localdb)\MSSQLLocalDB" -Q "ALTER LOGIN [sa] ENABLE"
    Write-Output "SqlLocalDB installed and accessible at (localdb)\MSSQLLocalDB"
}

$maxAttempts = 2
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    try {
        # sqlengine and localdb must run first (other tools may depend on the engine).
        if ("sqlengine" -in $Install) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            Install-SqlEngine
            $sw.Stop(); Write-Timing 'sqlengine' $sw
        }
        if ("localdb" -in $Install) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            Install-LocalDb
            $sw.Stop(); Write-Timing 'localdb' $sw
        }

        # sqlclient and sqlpackage are independent — install in parallel when both requested.
        $parallelTasks = @()
        if ("sqlclient"  -in $Install) { $parallelTasks += "sqlclient" }
        if ("sqlpackage" -in $Install) { $parallelTasks += "sqlpackage" }

        if ($parallelTasks.Count -gt 1) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $jobs = @()
            foreach ($task in $parallelTasks) {
                $jobs += Start-ThreadJob -ArgumentList $task, $showLog, $ismacos, $islinux, $iswindows -ScriptBlock {
                    param($task, $showLog, $ismacos, $islinux, $iswindows)
                    $ErrorActionPreference = 'Stop'
                    if ($task -eq "sqlclient") {
                        if ($ismacos) {
                            Write-Output "Installing sqlclient tools"
                            brew tap microsoft/mssql-release https://github.com/Microsoft/homebrew-mssql-release
                            $log = brew install microsoft/mssql-release/msodbcsql17 microsoft/mssql-release/mssql-tools
                            if ($LASTEXITCODE -ne 0) { throw "Failed to install sqlclient tools (exit code $LASTEXITCODE)" }
                            if ($showLog) { $log }
                        }
                        Write-Output "sqlclient tools installed"
                    } elseif ($task -eq "sqlpackage") {
                        Write-Output "Installing sqlpackage"
                        if ($ismacos -or $islinux) {
                            $url = if ($ismacos) { "https://aka.ms/sqlpackage-macos" } else { "https://aka.ms/sqlpackage-linux" }
                            curl $url -4 -sL -o '/tmp/sqlpackage.zip'
                            if ($LASTEXITCODE -ne 0) { throw "Failed to download sqlpackage from $url (exit code $LASTEXITCODE)" }
                            $log = unzip /tmp/sqlpackage.zip -d $HOME/sqlpackage
                            if ($LASTEXITCODE -ne 0) { throw "Failed to extract sqlpackage (exit code $LASTEXITCODE)" }
                            chmod +x $HOME/sqlpackage/sqlpackage
                            sudo ln -sf $HOME/sqlpackage/sqlpackage /usr/local/bin
                            if ($showLog) { $log; sqlpackage /version }
                        }
                        if ($iswindows) {
                            $log = choco install sqlpackage -y
                            if ($showLog) { $log; sqlpackage /version }
                        }
                        Write-Output "sqlpackage installed"
                    }
                }
            }
            $results = $jobs | Wait-Job | Receive-Job
            $failed = $jobs | Where-Object { $_.State -eq 'Failed' }
            $jobs | Remove-Job -Force
            if ($failed) {
                $errMsg = ($failed | ForEach-Object { $_.ChildJobs[0].JobStateInfo.Reason.Message }) -join '; '
                throw "Parallel install failed: $errMsg"
            }
            $results | ForEach-Object { Write-Output $_ }
            $sw.Stop(); Write-Timing 'sqlclient+sqlpackage (parallel)' $sw
        } elseif ($parallelTasks.Count -eq 1) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            if ("sqlclient"  -in $Install) { Install-SqlClient }
            if ("sqlpackage" -in $Install) { Install-SqlPackage }
            $sw.Stop(); Write-Timing ($parallelTasks[0]) $sw
        }
        break
    } catch {
        if ($attempt -lt $maxAttempts) {
            Write-Warning "Attempt $attempt failed: $($_.Exception.Message). Retrying..."
        } else {
            throw
        }
    }
}

$totalTimer.Stop()
Write-Output "========================================="
Write-Output "Total mssqlsuite install time: $($totalTimer.Elapsed.ToString('mm\:ss\.ff'))"
Write-Output "========================================="