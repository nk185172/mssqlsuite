param (
    [string]$path = (Join-Path ([System.IO.Path]::GetTempPath()) 'mssql'),
    [string]$version = "2019"
)

function Invoke-DownloadWithRetry {
    <#
    .SYNOPSIS
        Downloads a file from a given URL with retry functionality.

    .DESCRIPTION
        The Invoke-DownloadWithRetry function downloads a file from the specified URL
        to the specified path. It includes retry functionality in case the download fails.

    .PARAMETER Url
        The URL of the file to download.

    .PARAMETER Path
        The path where the downloaded file will be saved. If not provided, a temporary path
        will be used.

    .EXAMPLE
        Invoke-DownloadWithRetry -Url "https://example.com/file.zip" -Path "C:\Downloads\file.zip"
        Downloads the file from the specified URL and saves it to the specified path.

    .EXAMPLE
        Invoke-DownloadWithRetry -Url "https://example.com/file.zip"
        Downloads the file from the specified URL and saves it to a temporary path.

    .OUTPUTS
        The path where the downloaded file is saved.
    #>

    Param
    (
        [Parameter(Mandatory)]
        [string] $Url,
        [Alias("Destination")]
        [string] $Path
    )

    if (-not $Path) {
        $invalidChars = [IO.Path]::GetInvalidFileNameChars() -join ''
        $re = "[{0}]" -f [RegEx]::Escape($invalidChars)
        $fileName = [IO.Path]::GetFileName($Url) -replace $re

        if ([String]::IsNullOrEmpty($fileName)) {
            $fileName = [System.IO.Path]::GetRandomFileName()
        }
        $tempDir = $env:RUNNER_TEMP ?? [System.IO.Path]::GetTempPath()
        $Path = Join-Path -Path $tempDir -ChildPath $fileName
    }

    Write-Host "Downloading package from $Url to $Path..."

    $interval = 30
    $downloadStartTime = Get-Date
    $ProgressPreference = 'SilentlyContinue'
    for ($retries = 20; $retries -gt 0; $retries--) {
        try {
            $attemptStartTime = Get-Date
            Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing
            $attemptSeconds = [math]::Round(($(Get-Date) - $attemptStartTime).TotalSeconds, 2)
            Write-Host "Package downloaded in $attemptSeconds seconds"

            break

        } catch {
            $attemptSeconds = [math]::Round(($(Get-Date) - $attemptStartTime).TotalSeconds, 2)
            Write-Warning "Package download failed in $attemptSeconds seconds"
            Write-Warning $_.Exception.Message

            if ($_.Exception.Response.StatusCode -eq [System.Net.HttpStatusCode]::NotFound) {
                Write-Warning "Request returned 404 Not Found. Aborting download."
                $retries = 0
            }
        }

        # NOTE: this check must use -le 1, not -eq 0. The for-loop decrement runs
        # *after* this block, so when $retries is 1 the loop will exit silently on
        # the next iteration without ever reaching this check again.
        if ($retries -le 1) {
            $totalSeconds = [math]::Round(($(Get-Date) - $downloadStartTime).TotalSeconds, 2)
            throw "Package download failed after $totalSeconds seconds"
        }

        Write-Warning "Waiting $interval seconds before retrying (retries left: $retries)..."
        Start-Sleep -Seconds $interval
    }

    return $Path
}

function Invoke-DownloadWindowsSql {
    param(
        [string]$Path,
        [string]$Version
    )
    Write-Output "Downloading Windows SQL Server"

    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }

    $downloadUris = @{
        "2017" = @{
            Exe = "https://download.microsoft.com/download/E/F/2/EF23C21D-7860-4F05-88CE-39AA114B014B/SQLServer2017-DEV-x64-ENU.exe"
            Box = "https://download.microsoft.com/download/E/F/2/EF23C21D-7860-4F05-88CE-39AA114B014B/SQLServer2017-DEV-x64-ENU.box"
        }
        "2019" = @{
            Exe = "https://download.microsoft.com/download/7/c/1/7c14e92e-bdcb-4f89-b7cf-93543e7112d1/SQLServer2019-DEV-x64-ENU.exe"
            Box = "https://download.microsoft.com/download/7/c/1/7c14e92e-bdcb-4f89-b7cf-93543e7112d1/SQLServer2019-DEV-x64-ENU.box"
        }
        "2022" = @{
            Exe = "https://download.microsoft.com/download/3/8/d/38de7036-2433-4207-8eae-06e247e17b25/SQLServer2022-DEV-x64-ENU.exe"
            Box = "https://download.microsoft.com/download/3/8/d/38de7036-2433-4207-8eae-06e247e17b25/SQLServer2022-DEV-x64-ENU.box"
        }
    }

    $filesToDownload = @(
        @{ Url = $downloadUris[$Version].Exe; Dest = (Join-Path $Path 'sqlsetup.exe') }
        @{ Url = $downloadUris[$Version].Box; Dest = (Join-Path $Path 'sqlsetup.box') }
    )

    foreach ($file in $filesToDownload) {
        if (Test-Path $file.Dest) {
            Write-Host "Skipping, already exists: $($file.Dest)"
            continue
        }
        Invoke-DownloadWithRetry -Url $file.Url -Path $file.Dest
    }

    Write-Output "Download complete"
}

try {
    Invoke-DownloadWindowsSql -Path $path -Version $version
} catch {
    Write-Error "Error: $($_.Exception.Message)" -ErrorAction Stop
}
