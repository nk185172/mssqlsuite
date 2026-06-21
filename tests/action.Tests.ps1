BeforeAll {
    $scriptRoot = Split-Path -Parent $PSScriptRoot
}

Describe 'action.yml structure' {
    BeforeAll {
        $actionYaml = Get-Content "$scriptRoot\action.yml" -Raw
        # Basic YAML parsing via PowerShell (ConvertFrom-Yaml not built-in, so use string checks)
    }

    It 'has no YAML syntax errors' {
        $result = python -c "import yaml, sys; yaml.safe_load(open(r'$scriptRoot\action.yml')); print('valid')" 2>&1
        $result | Should -Be 'valid'
    }

    It 'defines all expected inputs' {
        $actionYaml = Get-Content "$scriptRoot\action.yml" -Raw
        $actionYaml | Should -Match 'install:'
        $actionYaml | Should -Match 'sa-password:'
        $actionYaml | Should -Match 'show-log:'
        $actionYaml | Should -Match 'collation:'
        $actionYaml | Should -Match 'version:'
        $actionYaml | Should -Match 'download-path:'
        $actionYaml | Should -Match 'download-only:'
    }

    It 'uses composite action type' {
        $actionYaml = Get-Content "$scriptRoot\action.yml" -Raw
        $actionYaml | Should -Match 'using: composite'
    }

    It 'includes cache steps' {
        $actionYaml = Get-Content "$scriptRoot\action.yml" -Raw
        $actionYaml | Should -Match 'actions/cache@v4'
    }

    It 'caches SQL Server installers for Windows' {
        $actionYaml = Get-Content "$scriptRoot\action.yml" -Raw
        $actionYaml | Should -Match 'Cache SQL Server installers'
        $actionYaml | Should -Match "mssql-installer-"
    }

    It 'caches sqlpackage' {
        $actionYaml = Get-Content "$scriptRoot\action.yml" -Raw
        $actionYaml | Should -Match 'Cache sqlpackage'
    }

    It 'caches Homebrew on macOS' {
        $actionYaml = Get-Content "$scriptRoot\action.yml" -Raw
        $actionYaml | Should -Match 'Cache Homebrew packages'
        $actionYaml | Should -Match "runner.os == 'macOS'"
    }

    It 'has default sa-password' {
        $actionYaml = Get-Content "$scriptRoot\action.yml" -Raw
        $actionYaml | Should -Match 'default: Qwe12345'
    }

    It 'has default version 2019' {
        $actionYaml = Get-Content "$scriptRoot\action.yml" -Raw
        $actionYaml | Should -Match 'default: "2019"'
    }

    It 'passes environment variables to main.ps1' {
        $actionYaml = Get-Content "$scriptRoot\action.yml" -Raw
        $actionYaml | Should -Match 'MSSQL_INSTALL:'
        $actionYaml | Should -Match 'MSSQL_VERSION:'
        $actionYaml | Should -Match 'MSSQL_COLLATION:'
        $actionYaml | Should -Match 'SA_PASSWORD:'
        $actionYaml | Should -Match 'MSSQL_SHOW_LOG:'
    }
}

Describe 'main.ps1 script validation' {
    It 'has no syntax errors' {
        $tokens = $null; $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            "$scriptRoot\main.ps1", [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
    }
}

Describe 'Test-Collation.ps1' {
    It 'has no syntax errors' {
        $tokens = $null; $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            "$scriptRoot\Test-Collation.ps1", [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
    }

    It 'requires ExpectedCollation parameter' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            "$scriptRoot\Test-Collation.ps1", [ref]$null, [ref]$null)
        $params = $ast.ParamBlock.Parameters
        $collationParam = $params | Where-Object { $_.Name.VariablePath.UserPath -eq 'ExpectedCollation' }
        $mandatory = $collationParam.Attributes | Where-Object { $_.TypeName.Name -eq 'Parameter' }
        $mandatory | Should -Not -BeNullOrEmpty
    }
}
