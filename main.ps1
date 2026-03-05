param (
    [ValidateSet("sqlclient", "sqlpackage", "sqlengine", "localdb")]
    [string[]]$Install,
    [string]$SaPassword,
    [string]$ShowLog,
    [string]$Collation = "SQL_Latin1_General_CP1_CI_AS",
    [ValidateSet("2022", "2019", "2017")]
    [string]$Version = "2019",
    [string]$Path = 'C:\temp'
)

function Write-DockerLog {
    docker ps -a
    docker logs -t sql
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
            Start-Sleep -Seconds 3
        }
    } while ((Get-Date) -lt $deadline)
    throw "SQL Server at ${HostName}:${Port} did not become available within $TimeoutSeconds seconds"
}

function Install-SqlEngine {
    Write-Output "Installing SQL Engine"

    if ($ismacos) {
        Write-Output "macOS detected, installing Docker then pulling SQL Server container"
        $Env:HOMEBREW_NO_AUTO_UPDATE = 1
        brew install docker
        colima start --runtime docker
        docker run -e "ACCEPT_EULA=Y" -e "SA_PASSWORD=$SaPassword" -e "MSSQL_COLLATION=$Collation" --name sql -p 1433:1433 --memory="2g" -d "mcr.microsoft.com/mssql/server:$Version-latest"
        Write-Output "Docker container started"
        Start-Sleep 5
        if ($ShowLog -eq 'true') { Write-DockerLog }
        Write-Output "SQL Engine installed at localhost"
    }

    if ($islinux) {
        Write-Output "Linux detected, pulling SQL Server docker container"
        docker run -e "ACCEPT_EULA=Y" -e "SA_PASSWORD=$SaPassword" -e "MSSQL_COLLATION=$Collation" --name sql -p 1433:1433 -d "mcr.microsoft.com/mssql/server:$Version-latest"
        Write-Output "Waiting for SQL Server to start"
        Start-Sleep -Seconds 10
        if ($ShowLog -eq 'true') { Write-DockerLog }
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
        . $PSScriptRoot\download.ps1 -Path $Path -Version $Version

        Start-Process -Wait -FilePath ./sqlsetup.exe -ArgumentList /qs, /x:setup
        $setup = Get-Item -Path .\setup\setup.exe -ErrorAction Ignore
        Write-Output "SQL Server setup path: $setup"

        if ($null -ne $setup) {
            . $setup /q /ACTION=Install /INSTANCENAME=MSSQLSERVER /ASSYSADMINACCOUNTS='BUILTIN\ADMINISTRATORS' /FEATURES='SQLENGINE,FULLTEXT' /FILESTREAMLEVEL=3 /UPDATEENABLED=0 /FILESTREAMSHARENAME=MSSQLSERVER /SQLSVCACCOUNT='NT SERVICE\MSSQLSERVER' /SQLSYSADMINACCOUNTS='BUILTIN\ADMINISTRATORS' /TCPENABLED=1 /NPENABLED=0 /IACCEPTSQLSERVERLICENSETERMS /SQLCOLLATION=$Collation $installOptions

            Set-ItemProperty -path "HKLM:\Software\Microsoft\Microsoft SQL Server\MSSQL$versionMajor.MSSQLSERVER\MSSQLSERVER\" -Name LoginMode -Value 2
            Restart-Service MSSQLSERVER
            sqlcmd -S localhost -q "ALTER LOGIN [sa] WITH PASSWORD=N'$SaPassword'"
            sqlcmd -S localhost -q "ALTER LOGIN [sa] ENABLE"
            Pop-Location

            Write-Output "SQL Server $Version installed at localhost (Windows and SQL auth enabled)"
        } else {
            Write-Error "setup.exe not found"
        }
    }
}

function Install-SqlClient {
    if ($ismacos) {
        Write-Output "Installing sqlclient tools"
        brew tap microsoft/mssql-release https://github.com/Microsoft/homebrew-mssql-release
        #$null = brew update
        $log = brew install microsoft/mssql-release/msodbcsql17 microsoft/mssql-release/mssql-tools
        if ($ShowLog -eq 'true') { $log }
    }
    Write-Output "sqlclient tools installed"
}

function Install-SqlPackage {
    Write-Output "Installing sqlpackage"

    if ($ismacos -or $islinux) {
        $url = if ($ismacos) { "https://aka.ms/sqlpackage-macos" } else { "https://aka.ms/sqlpackage-linux" }
        curl $url -4 -sL -o '/tmp/sqlpackage.zip'
        $log = unzip /tmp/sqlpackage.zip -d $HOME/sqlpackage
        chmod +x $HOME/sqlpackage/sqlpackage
        sudo ln -sf $HOME/sqlpackage/sqlpackage /usr/local/bin
        if ($ShowLog -eq 'true') {
            $log
            sqlpackage /version
        }
    }

    if ($iswindows) {
        $log = choco install sqlpackage
        if ($ShowLog -eq 'true') {
            $log
            sqlpackage /version
        }
    }

    Write-Output "sqlpackage installed"
}

function Install-LocalDb {
    if (-not $iswindows) {
        Write-Output "LocalDB can only be installed on Windows"
        return
    }

    if ($Version -eq "2022") {
        Write-Output "LocalDB for SQL Server 2022 is not yet available"
        return
    }

    $msiUrls = @{
        "2017" = "https://download.microsoft.com/download/E/F/2/EF23C21D-7860-4F05-88CE-39AA114B014B/SqlLocalDB.msi"
        "2019" = "https://download.microsoft.com/download/7/c/1/7c14e92e-bdcb-4f89-b7cf-93543e7112d1/SqlLocalDB.msi"
    }

    Write-Host "Downloading SqlLocalDB"
    $ProgressPreference = "SilentlyContinue"
    Invoke-WebRequest -Uri $msiUrls[$Version] -OutFile SqlLocalDB.msi
    Write-Host "Installing SqlLocalDB"
    Start-Process -FilePath "SqlLocalDB.msi" -Wait -ArgumentList "/qn", "/norestart", "/l*v SqlLocalDBInstall.log", "IACCEPTSQLLOCALDBLICENSETERMS=YES"
    Write-Host "Verifying installation"
    sqlcmd -S "(localdb)\MSSQLLocalDB" -Q "SELECT @@VERSION;"
    sqlcmd -S "(localdb)\MSSQLLocalDB" -Q "ALTER LOGIN [sa] WITH PASSWORD=N'$SaPassword'"
    sqlcmd -S "(localdb)\MSSQLLocalDB" -Q "ALTER LOGIN [sa] ENABLE"
    Write-Host "SqlLocalDB $Version installed at (localdb)\MSSQLLocalDB"
}

if ("sqlengine" -in $Install) { Install-SqlEngine }
if ("sqlclient" -in $Install) { Install-SqlClient }
if ("sqlpackage" -in $Install) { Install-SqlPackage }
if ("localdb"   -in $Install) { Install-LocalDb }