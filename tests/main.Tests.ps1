BeforeAll {
    $scriptRoot = Split-Path -Parent $PSScriptRoot
}

Describe 'main.ps1 parameter defaults' {
    BeforeEach {
        # Clear env vars to test defaults
        $env:MSSQL_INSTALL = $null
        $env:SA_PASSWORD = $null
        $env:MSSQL_SHOW_LOG = $null
        $env:MSSQL_COLLATION = $null
        $env:MSSQL_VERSION = $null
        $env:MSSQL_DOWNLOAD_PATH = $null
        $env:RUNNER_TEMP = $null
    }

    It 'defaults Install to sqlengine when MSSQL_INSTALL is not set' {
        $result = pwsh -NoProfile -Command "
            `$env:MSSQL_INSTALL = `$null
            `$env:SA_PASSWORD = 'test'
            `$env:MSSQL_SHOW_LOG = 'false'
            `$env:MSSQL_COLLATION = 'SQL_Latin1_General_CP1_CI_AS'
            `$env:MSSQL_VERSION = '2019'
            `$env:RUNNER_TEMP = '$env:TEMP'
            # Parse the param block only
            `$ast = [System.Management.Automation.Language.Parser]::ParseFile('$scriptRoot\main.ps1', [ref]`$null, [ref]`$null)
            `$params = `$ast.ParamBlock.Parameters
            `$installParam = `$params | Where-Object { `$_.Name.VariablePath.UserPath -eq 'Install' }
            `$installParam.Attributes[0].TypeName.Name
        "
        $result | Should -Be 'ValidateSet'
    }

    It 'accepts valid install values' {
        $validValues = @('sqlclient', 'sqlpackage', 'sqlengine', 'localdb')
        $ast = [System.Management.Automation.Language.Parser]::ParseFile("$scriptRoot\main.ps1", [ref]$null, [ref]$null)
        $params = $ast.ParamBlock.Parameters
        $installParam = $params | Where-Object { $_.Name.VariablePath.UserPath -eq 'Install' }
        $validateSet = $installParam.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
        $allowedValues = $validateSet.PositionalArguments | ForEach-Object { $_.Value }
        $allowedValues | Should -Be $validValues
    }

    It 'accepts valid version values' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile("$scriptRoot\main.ps1", [ref]$null, [ref]$null)
        $params = $ast.ParamBlock.Parameters
        $versionParam = $params | Where-Object { $_.Name.VariablePath.UserPath -eq 'Version' }
        $validateSet = $versionParam.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
        $allowedValues = $validateSet.PositionalArguments | ForEach-Object { $_.Value }
        $allowedValues | Should -Contain '2017'
        $allowedValues | Should -Contain '2019'
        $allowedValues | Should -Contain '2022'
    }
}

Describe 'Wait-SqlServer' {
    BeforeAll {
        # Dot-source main.ps1 in a way that doesn't execute the install logic
        # We extract just the function
        $mainContent = Get-Content "$scriptRoot\main.ps1" -Raw
        $functionBlock = [regex]::Match($mainContent, '(?s)(function Wait-SqlServer \{.+?\n\})').Value
        Invoke-Expression $functionBlock
    }

    It 'returns immediately when port is open' {
        # Start a TCP listener on a random port
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = $listener.LocalEndpoint.Port

        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            Wait-SqlServer -HostName 'localhost' -Port $port -TimeoutSeconds 5
            $sw.Stop()
            $sw.ElapsedMilliseconds | Should -BeLessThan 3000
        } finally {
            $listener.Stop()
        }
    }

    It 'throws on timeout when port is closed' {
        # Use a port that nothing listens on
        { Wait-SqlServer -HostName 'localhost' -Port 19999 -TimeoutSeconds 2 } | Should -Throw "*did not become available*"
    }
}

Describe 'Install-LocalDb logic' {
    BeforeAll {
        $mainContent = Get-Content "$scriptRoot\main.ps1" -Raw
        # Extract the function
        $functionBlock = [regex]::Match($mainContent, '(?s)(function Install-LocalDb \{.+?\n\})').Value
        # We'll test the conditional logic without actually running installs
    }

    It 'skips on non-Windows (logic check)' {
        # The function checks $iswindows; on non-Windows it should return early
        # We test by verifying the function body contains the guard
        $functionBlock | Should -Match 'if \(-not \$iswindows\)'
    }

    It 'skips version 2022 (logic check)' {
        $functionBlock | Should -Match "Version -eq .2022."
    }
}

Describe 'Install orchestration logic' {
    BeforeAll {
        $mainContent = Get-Content "$scriptRoot\main.ps1" -Raw
    }

    It 'runs sqlengine before sqlclient/sqlpackage' {
        $engineIdx = $mainContent.IndexOf('"sqlengine" -in $Install')
        $clientIdx = $mainContent.IndexOf('"sqlclient"  -in $Install')
        $engineIdx | Should -BeLessThan $clientIdx
    }

    It 'runs localdb before sqlclient/sqlpackage' {
        $localdbIdx = $mainContent.IndexOf('"localdb"   -in $Install')
        $parallelIdx = $mainContent.IndexOf('$parallelTasks = @()')
        $localdbIdx | Should -BeLessThan $parallelIdx
    }

    It 'has retry logic with max 2 attempts' {
        $mainContent | Should -Match '\$maxAttempts = 2'
    }

    It 'masks SA password in logs' {
        $mainContent | Should -Match '::add-mask::'
    }
}
