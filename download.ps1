param (
    [string]$path = 'C:\temp',
    [string]$version = "2019"
)

$CURRENT = split-path -parent $MyInvocation.MyCommand.Definition

function DownloadWindowsSql($path, $version)
{
    Write-Output "downloading windows sql server"

    if (-not (Test-Path $path)) {
        mkdir $path
    }

    Push-Location $path
    $ProgressPreference = 'Continue'

    switch ($version) {
        "2017" {
            $exeUri = "https://download.microsoft.com/download/E/F/2/EF23C21D-7860-4F05-88CE-39AA114B014B/SQLServer2017-DEV-x64-ENU.exe"
            $boxUri = "https://download.microsoft.com/download/E/F/2/EF23C21D-7860-4F05-88CE-39AA114B014B/SQLServer2017-DEV-x64-ENU.box"
        }
        "2019" {
            $exeUri = "https://download.microsoft.com/download/7/c/1/7c14e92e-bdcb-4f89-b7cf-93543e7112d1/SQLServer2019-DEV-x64-ENU.exe"
            $boxUri = "https://download.microsoft.com/download/7/c/1/7c14e92e-bdcb-4f89-b7cf-93543e7112d1/SQLServer2019-DEV-x64-ENU.box"
        }
        "2022" {
            $exeUri = "https://download.microsoft.com/download/3/8/d/38de7036-2433-4207-8eae-06e247e17b25/SQLServer2022-DEV-x64-ENU.exe"
            $boxUri = "https://download.microsoft.com/download/3/8/d/38de7036-2433-4207-8eae-06e247e17b25/SQLServer2022-DEV-x64-ENU.box"
        }
    }

    if (!(Test-Path(".\sqlsetup.exe")))
    {
        Write-Host "`ndownloading sqlsetup.exe"
        Invoke-WebRequest -Uri $exeUri -OutFile sqlsetup.exe
    }
    else
    {
        Write-Host "downloading sqlsetup.exe was skipped"
    }

    if (!(Test-Path(".\sqlsetup.box")))
    {
        Write-Host "`ndownloading sqlsetup.box"
        Invoke-WebRequest -Uri $boxUri -OutFile sqlsetup.box
    }
    else
    {
        Write-Host "downloading sqlsetup.box was skipped"
    }

    Write-Output "downloading complete"
}

try
{
    DownloadWindowsSql $path $version
}
catch
{
    Write-Error "Error: $($_.Exception.Message)" -ErrorAction Stop
}
finally
{
    Push-Location $CURRENT
}
