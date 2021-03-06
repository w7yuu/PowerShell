# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

##
## ----------
## Test Note:
## ----------
## Since these tests change session and system state (constrained language and system lockdown)
## they will all use try/finally blocks instead of Pester AfterEach/AfterAll to ensure session
## and system state is restored.
## Pester AfterEach, AfterAll is not reliable when the session is constrained language or locked down.
##

Import-Module HelpersSecurity

try
{
    $defaultParamValues = $PSDefaultParameterValues.Clone()
    $PSDefaultParameterValues["it:Skip"] = !$IsWindows

    Describe "Help built-in function should not expose nested module private functions when run on locked down systems" -Tags 'Feature','RequireAdminOnWindows' {

        BeforeAll {

            $restorePSModulePath = $env:PSModulePath
            $env:PSModulePath += ";$TestDrive"

            $trustedModuleName1 = "TrustedModule$(Get-Random -Max 999)_System32"
            $trustedModulePath1 = Join-Path $TestDrive $trustedModuleName1
            New-Item -ItemType Directory $trustedModulePath1
            $trustedModuleFilePath1 = Join-Path $trustedModulePath1 ($trustedModuleName1 + ".psm1")
            $trustedModuleManifestPath1 = Join-Path $trustedModulePath1 ($trustedModuleName1 + ".psd1")

            $trustedModuleName2 = "TrustedModule$(Get-Random -Max 999)_System32"
            $trustedModulePath2 = Join-Path $TestDrive $trustedModuleName2
            New-Item -ItemType Directory $trustedModulePath2
            $trustedModuleFilePath2 = Join-Path $trustedModulePath2 ($trustedModuleName2 + ".psm1")

            $trustedModuleScript1 = @'
            function PublicFn1
            {
                NestedFn1
                PrivateFn1
            }
            function PrivateFn1
            {
                "PrivateFn1"
            }
'@
            $trustedModuleScript1 | Out-File -FilePath $trustedModuleFilePath1
            '@{{ FunctionsToExport = "PublicFn1"; ModuleVersion = "1.0"; RootModule = "{0}"; NestedModules = "{1}" }}' -f @($trustedModuleFilePath1,$trustedModuleName2) | Out-File -FilePath $trustedModuleManifestPath1

            $trustedModuleScript2 = @'
            function NestedFn1
            {
                "NestedFn1"
                "Language mode is $($ExecutionContext.SessionState.LanguageMode)"
            }
'@
            $trustedModuleScript2 | Out-File -FilePath $trustedModuleFilePath2
        }

        AfterAll {

            $env:PSModulePath = $restorePSModulePath
            if ($trustedModuleName1 -ne $null) { Remove-Module -Name $trustedModuleName1 -Force -ErrorAction Ignore }
            if ($trustedModuleName2 -ne $null) { Remove-Module -Name $trustedModuleName2 -Force -ErrorAction Ignore }
        }

        It "Verifies that private functions in trusted nested modules are not globally accessible after running the help function" {

            $isCommandAccessible = "False"
            try
            {
                Invoke-LanguageModeTestingSupportCmdlet -SetLockdownMode
                $ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"

                $command = @"
                Import-Module -Name $trustedModuleName1 -Force -ErrorAction Stop;
"@
                $command += @'
                $null = help NestedFn1 2> $null;
                $result = Get-Command NestedFn1 2> $null;
                return ($result -ne $null)
'@
                $isCommandAccessible = powershell.exe -noprofile -nologo -c $command
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -RevertLockdownMode -EnableFullLanguageMode
            }

            # Verify that nested function NestedFn1 was not accessible
            $isCommandAccessible | Should -BeExactly "False"
        }
    }

    Describe "NoLanguage runspace pool session should remain in NoLanguage mode when created on a system-locked down machine" -Tags 'Feature','RequireAdminOnWindows' {

        BeforeAll {

            $configFileName = "RestrictedSessionConfig.pssc"
            $configFilePath = Join-Path $TestDrive $configFileName
            '@{ SchemaVersion = "2.0.0.0"; SessionType = "RestrictedRemoteServer"}' > $configFilePath

            $scriptModuleName = "ImportTrustedModuleForTest_System32"
            $moduleFilePath = Join-Path $TestDrive ($scriptModuleName + ".psm1")
            $template = @'
            function TestRestrictedSession
            {{
                $iss = [initialsessionstate]::CreateFromSessionConfigurationFile("{0}")
                $rsp = [runspacefactory]::CreateRunspacePool($iss)
                $rsp.Open()
                $ps = [powershell]::Create()
                $ps.RunspacePool = $rsp
                $null = $ps.AddScript("Hello")

                try
                {{
                    $ps.Invoke()
                }}
                finally
                {{
                    $ps.Dispose()
                    $rsp.Dispose()
                }}
            }}

            Export-ModuleMember -Function TestRestrictedSession
'@
            $template -f $configFilePath > $moduleFilePath
        }

        It "Verifies that a NoLanguage runspace pool throws the expected 'script not allowed' error" {

            try
            {
                Invoke-LanguageModeTestingSupportCmdlet -SetLockdownMode
                $ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"

                $mod = Import-Module -Name $moduleFilePath -Force -PassThru

                # Running module function TestRestrictedSession should throw a 'script not allowed' error
                # because it runs in a 'no language' session.
                try
                {
                    & "$scriptModuleName\TestRestrictedSession"
                    throw "No Exception!"
                }
                catch
                {
                    $expectedError = $_
                }
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -RevertLockdownMode -EnableFullLanguageMode
            }

            $expectedError.Exception.InnerException.ErrorRecord.FullyQualifiedErrorId | Should -BeExactly "ScriptsNotAllowed"
        }
    }

    Describe "Built-ins work within constrained language" -Tags 'Feature','RequireAdminOnWindows' {

        BeforeAll {
            $TestCasesBuiltIn = @(
                @{testName = "Verify built-in function"; scriptblock = { Get-Verb } }
                @{testName = "Verify built-in error variable"; scriptblock = { Write-Error SomeError -ErrorVariable ErrorOutput -ErrorAction SilentlyContinue; $ErrorOutput} }
            )
        }

        It "<testName>" -TestCases $TestCasesBuiltIn {

            param ($scriptblock)

            try
            {
                $ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"

                $result = (& $scriptblock)
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $result.Count | Should -BeGreaterThan 0
        }
    }

    Describe "Background jobs" -Tags 'Feature','RequireAdminOnWindows' {

        Context "Background jobs in system lock down mode" {

            It "Verifies that background jobs in system lockdown mode run in constrained language" {

                try
                {
                    Invoke-LanguageModeTestingSupportCmdlet -SetLockdownMode

                    $job = Start-Job -ScriptBlock { [object]::Equals("A", "B") } | Wait-Job
                    $expectedErrorId = $job.ChildJobs[0].Error.FullyQualifiedErrorId
                    $job | Remove-Job
                }
                finally
                {
                    Invoke-LanguageModeTestingSupportCmdlet -RevertLockdownMode -EnableFullLanguageMode
                }

                $expectedErrorId | Should -BeExactly "MethodInvocationNotSupportedInConstrainedLanguage"
            }
        }

        Context "Background jobs within inconsistent mode" {

            It "Verifies that background job is denied when mode is inconsistent" {

                try
                {
                    $ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"
                    Start-Job { [object]::Equals("A", "B") }
                    throw "No Exception!"
                }
                catch
                {
                    $expectedError = $_
                }
                finally
                {
                    Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
                }

                $expectedError.FullyQualifiedErrorId | Should -BeExactly "CannotStartJobInconsistentLanguageMode,Microsoft.PowerShell.Commands.StartJobCommand"
            }
        }
    }

    Describe "Add-Type in constrained language" -Tags 'Feature','RequireAdminOnWindows' {

        It "Verifies Add-Type fails in constrained language mode" {

            try
            {
                $ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"
                Add-Type -TypeDefinition 'public class ConstrainedLanguageTest { public static string Hello = "HelloConstrained"; }'
                throw "No Exception!"
            }
            catch
            {
                $expectedError = $_
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $expectedError.FullyQualifiedErrorId | Should -BeExactly "CannotDefineNewType,Microsoft.PowerShell.Commands.AddTypeCommand"
        }

        It "Verifies Add-Type works back in full language mode again" {
            Add-Type -TypeDefinition 'public class AfterFullLanguageTest { public static string Hello = "HelloAfter"; }'
            [AfterFullLanguageTest]::Hello | Should -BeExactly "HelloAfter"
        }
    }

    Describe "New-Object in constrained language" -Tags 'Feature','RequireAdminOnWindows' {

        Context "New-Object with dotNet types" {

            It "Verifies New-Object works in constrained language of allowed string type" {

                try
                {
                    $ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"

                    $resultString = New-Object System.String "Hello"
                }
                finally
                {
                    Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
                }

                $resultString | Should -Be "Hello"
            }

            It "Verifies New-Object throws error in constrained language for disallowed IntPtr type" {

                try
                {
                    $ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"
                    New-Object System.IntPtr 1234
                    throw "No Exception!"
                }
                catch
                {
                    $expectedError = $_
                }
                finally
                {
                    Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
                }

                $expectedError.FullyQualifiedErrorId | Should -BeExactly "CannotCreateTypeConstrainedLanguage,Microsoft.PowerShell.Commands.NewObjectCommand"
            }

            It "Verifies New-Object works for IntPtr type back in full language mode again" {

                New-Object System.IntPtr 1234 | Should -Be 1234
            }
        }

        Context "New-Object with COM types" {

            It "Verifies New-Object with COM types is disallowed in system lock down" {

                try
                {
                    $ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"
                    Invoke-LanguageModeTestingSupportCmdlet -SetLockdownMode

                    New-Object -Com ADODB.Parameter
                    throw "No Exception!"
                }
                catch
                {
                    $expectedError = $_
                }
                finally
                {
                    Invoke-LanguageModeTestingSupportCmdlet -RevertLockdownMode -EnableFullLanguageMode
                }

                $expectedError.FullyQualifiedErrorId | Should -BeExactly "CannotCreateComTypeConstrainedLanguage,Microsoft.PowerShell.Commands.NewObjectCommand"
            }

            It "Verifies New-Object with COM types works back in full language mode again" {

                $result = New-Object -ComObject ADODB.Parameter
                $result.Direction | Should -Be 1
            }
        }
    }

    Describe "New-Item command on function drive in constrained language" -Tags 'Feature','RequireAdminOnWindows' {

        It "Verifies New-Item directory on function drive is not allowed in constrained language mode" {

            try
            {
                $ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"
                $null = New-Item -Path function:\SomeEvilFunction -ItemType Directory -Value SomeBadScriptBlock -ErrorAction Stop
                throw "No Exception!"
            }
            catch
            {
                $expectedError = $_
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $expectedError.FullyQualifiedErrorId | Should -BeExactly "NotSupported,Microsoft.PowerShell.Commands.NewItemCommand"
        }
    }

    Describe "Script debugging in constrained language" -Tags 'Feature','RequireAdminOnWindows' {

        It "Verifies that a debugging breakpoint cannot be set in constrained language and no system lockdown" {

            try
            {
                $ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"
                function MyDebuggerFunction {}

                Set-PSBreakpoint -Command MyDebuggerFunction
                throw "No Exception!"
            }
            catch
            {
                $expectedError = $_
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $expectedError.FullyQualifiedErrorId | Should -BeExactly "CannotSetBreakpointInconsistentLanguageMode,Microsoft.PowerShell.Commands.SetPSBreakpointCommand"
        }

        It "Verifies that a debugging breakpoint can be set in constrained language with system lockdown" {

            try
            {
                $ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"
                Invoke-LanguageModeTestingSupportCmdlet -SetLockdownMode

                function MyDebuggerFunction2 {}
                $Global:DebuggingOk = $null
                $null = Set-PSBreakpoint -Command MyDebuggerFunction2 -Action { $Global:DebuggingOk = "DebuggingOk" }
                MyDebuggerFunction2
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -RevertLockdownMode -EnableFullLanguageMode
            }

            $Global:DebuggingOk | Should -BeExactly "DebuggingOk"
        }

        It "Verifies that debugger commands do not run in full language mode when system is locked down" {

            try
            {
                $ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"

                function MyDebuggerFunction3 {}

                & {
                    $null = Set-PSBreakpoint -Command MyDebuggerFunction3 -Action { $Global:dbgResult = [object]::Equals("A", "B") }
                    $restoreEAPreference = $ErrorActionPreference
                    $ErrorActionPreference = "Stop"
                    MyDebuggerFunction3
                }
                throw "No Exception!"
            }
            catch
            {
                $expectedError = $_
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
                if ($restoreEAPreference -ne $null) { $ErrorActionPreference = $restoreEAPreference }
            }

            $expectedError.FullyQualifiedErrorId | Should -BeExactly "CannotSetBreakpointInconsistentLanguageMode,Microsoft.PowerShell.Commands.SetPSBreakpointCommand"
        }

        It "Verifies that debugger command injection is blocked in system lock down" {

            $trustedScriptContent = @'
            function Trusted
            {
                param ($UserInput)

                Add-Type -TypeDefinition $UserInput
                try { $null = New-Object safe_738057 -ErrorAction Ignore } catch {}
                try { $null = New-Object pwnd_738057 -ErrorAction Ignore } catch {}
            }

            Trusted -UserInput 'public class safe_738057 { public safe_738057() { System.Environment.SetEnvironmentVariable("pwnd_738057", "False"); } }'

            "Hello World"
'@
            $trustedFile = Join-Path $TestDrive CommandInjectionDebuggingBlocked_System32.ps1

            try
            {
                $ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"
                Invoke-LanguageModeTestingSupportCmdlet -SetLockdownMode

                Set-Content $trustedScriptContent -Path $trustedFile
                $env:pwnd_738057 = "False"
                Set-PSBreakpoint -Script $trustedFile -Line 12 -Action { Trusted -UserInput 'public class pwnd_738057 { public pwnd_738057() { System.Environment.SetEnvironmentVariable("pwnd_738057", "Pwnd"); } }' }
                & $trustedFile
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -RevertLockdownMode -EnableFullLanguageMode
            }

            $env:pwnd_738057 | Should -Not -Be "Pwnd"
        }
    }

    Describe "Engine events in constrained language mode" -Tags 'Feature','RequireAdminOnWindows' {

        It "Verifies engine event in constrained language mode, its action runs as constrained" {

            try
            {
                $ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"

                $job = Register-EngineEvent LockdownEvent -Action { [object]::Equals("A", "B") }
                $null = New-Event LockdownEvent
                Wait-Job $job
                Unregister-Event LockdownEvent
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $job.Error.FullyQualifiedErrorId | Should -Match "MethodInvocationNotSupportedInConstrainedLanguage"
        }
    }

    Describe "Module scope scripts in constrained language mode" -Tags 'Feature','RequireAdminOnWindows' {

        It "Verifies that while in constrained language mode script run in a module scope also runs constrained" {
            Import-Module PSDiagnostics
            $module = Get-Module PSDiagnostics

            try
            {
                $ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"
                & $module { [object]::Equals("A", "B") }
            }
            catch
            {
                $expectedError = $_
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $expectedError.FullyQualifiedErrorId | Should -BeExactly "CantInvokeCallOperatorAcrossLanguageBoundaries"
        }
    }

    Describe "Switch -file in constrained language mode" -Tags 'Feature','RequireAdminOnWindows' {

        It "Verifies that switch -file will not work in constrained language without provider" {

            [initialsessionstate] $iss = [initialsessionstate]::Create()
            $iss.LanguageMode = "ConstrainedLanguage"
            [runspace] $rs = [runspacefactory]::CreateRunspace($iss)
            $rs.Open()
            $pl = $rs.CreatePipeline("switch -file $testDrive/foo.txt { 'A' { 'B' } }")

            $e = { $pl.Invoke() } | Should -Throw -ErrorId "DriveNotFoundException"

            $rs.Dispose()
        }
    }

    Describe "Get content syntax in constrained language mode" -Tags 'Feature','RequireAdminOnWindows' {

        It "Verifies that the get content syntax returns null value in constrained language without provider" {

            $iss = [initialsessionstate]::Create()
            $iss.LanguageMode = "ConstrainedLanguage"
            $rs = [runspacefactory]::CreateRunspace($iss)
            $rs.Open()
            $pl = $rs.CreatePipeline('${' + "$testDrive/foo.txt}")

            $result = $pl.Invoke()
            $rs.Dispose()

            $result[0] | Should -BeNullOrEmpty
        }
    }

    Describe "Stream redirection in constrained language mode" -Tags 'Feature','RequireAdminOnWindows' {

        It "Verifies that stream redirection doesn't work in constrained language mode without provider" {

            $iss = [initialsessionstate]::CreateDefault2()
            $iss.Providers.Clear()
            $iss.LanguageMode = "ConstrainedLanguage"
            $rs = [runspacefactory]::CreateRunspace($iss)
            $rs.Open()
            $pl = $rs.CreatePipeline('"Hello" > c:\temp\foo.txt')

            $e = { $pl.Invoke() } | Should -Throw -ErrorId "CmdletInvocationException"

            $rs.Dispose()
        }
    }

    Describe "Invoke-Expression in constrained language mode" -Tags 'Feature','RequireAdminOnWindows' {

        BeforeAll {

            function VulnerableFunctionFromFullLanguage { Invoke-Expression $Args[0] }

            $TestCasesIEX = @(
                @{testName = "Verifies direct Invoke-Expression does not bypass constrained language mode";
                  scriptblock = { Invoke-Expression '[object]::Equals("A", "B")' } }
                @{testName = "Verifies indirect Invoke-Expression does not bypass constrained language mode";
                  scriptblock = { VulnerableFunctionFromFullLanguage '[object]::Equals("A", "B")' } }
            )
        }

        It "<testName>" -TestCases $TestCasesIEX {

            param ($scriptblock)

            try
            {
                $ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"
                & $scriptblock
                throw "No Exception!"
            }
            catch
            {
                $expectedError = $_
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $expectedError.FullyQualifiedErrorId | Should -BeExactly "MethodInvocationNotSupportedInConstrainedLanguage,Microsoft.PowerShell.Commands.InvokeExpressionCommand"
        }
    }

    Describe "Dynamic method invocation in constrained language mode" -Tags 'Feature','RequireAdminOnWindows' {

        It "Verifies dynamic method invocation does not bypass constrained language mode" {

            try
            {
                $ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"
                & {
                    $type = [IO.Path]
                    $method = "GetRandomFileName"
                    $type::$method()
                }
                throw "No Exception!"
            }
            catch
            {
                $expectedError = $_
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $expectedError.FullyQualifiedErrorId | Should -BeExactly "MethodInvocationNotSupportedInConstrainedLanguage"
        }

        It "Verifies dynamic methods invocation does not bypass constrained language mode" {

            try
            {
                $ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"
                & {
                    $type = [IO.Path]
                    $methods = "GetRandomFileName","GetTempPath"
                    $type::($methods[0])()
                }
                throw "No Exception!"
            }
            catch
            {
                $expectedError = $_
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $expectedError.FullyQualifiedErrorId | Should -BeExactly "MethodInvocationNotSupportedInConstrainedLanguage"
        }
    }

    Describe "Tab expansion in constrained language mode" -Tags 'Feature','RequireAdminOnWindows' {

        It "Verifies that tab expansion cannot convert disallowed IntPtr type" {

            try
            {
                $ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"

                $result = @(TabExpansion2 '(1234 -as [IntPtr]).' 20 | ForEach-Object CompletionMatches | Where-Object CompletionText -Match Pointer)
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $result.Count | Should -Be 0
        }
    }

    Describe "Variable AllScope in constrained language mode" -Tags 'Feature','RequireAdminOnWindows' {

        It "Verifies Set-Variable cannot create AllScope in constrained language" {

            try
            {
                $ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"
                Set-Variable -Name SetVariableAllScopeNotSupported -Value bar -Option AllScope
                throw "No Exception!"
            }
            catch
            {
                $expectedError = $_
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $expectedError.FullyQualifiedErrorId | Should -BeExactly "NotSupported,Microsoft.PowerShell.Commands.SetVariableCommand"
        }

        It "Verifies New-Variable cannot create AllScope in constrained language" {

            try
            {
                $ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"
                New-Variable -Name NewVarialbeAllScopeNotSupported -Value bar -Option AllScope
                throw "No Exception!"
            }
            catch
            {
                $expectedError = $_
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $expectedError.FullyQualifiedErrorId | Should -BeExactly "NotSupported,Microsoft.PowerShell.Commands.NewVariableCommand"
        }
    }

    Describe "Data section additional commands in constrained language" -Tags 'Feature','RequireAdminOnWindows' {

        function InvokeDataSectionConstrained
        {
            try
            {
                Invoke-Expression 'data foo -SupportedCommand Add-Type { Add-Type }'
                throw "No Exception!"
            }
            catch
            {
                return $_
            }
        }

        It "Verifies data section Add-Type additional command is disallowed in constrained language" {

            try
            {
                $ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"

                $exception1 = InvokeDataSectionConstrained
                # Repeat to make sure the first time properly restored the language mode to constrained.
                $exception2 = InvokeDataSectionConstrained
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $exception1.FullyQualifiedErrorId | Should -Match "DataSectionAllowedCommandDisallowed"
            $exception2.FullyQualifiedErrorId | Should -Match "DataSectionAllowedCommandDisallowed"
        }

        It "Verifies data section with no-constant expression Add-Type additional command is disallowed in constrained language" {

            try
            {
                $ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"
                $addedCommand = "Add-Type"
                Invoke-Expression 'data foo -SupportedCommand $addedCommand { Add-Type }'
                throw "No Exception!"
            }
            catch
            {
                $expectedError = $_
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $expectedError.FullyQualifiedErrorId | Should -BeExactly "DataSectionAllowedCommandDisallowed,Microsoft.PowerShell.Commands.InvokeExpressionCommand"
        }
    }

    Describe "Import-LocalizedData additional commands in constrained language" -Tags 'Feature','RequireAdminOnWindows' {

        It "Verifies Import-LocalizedData disallows Add-Type in constrained language" {

            try
            {
                $ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"
                & {
                    $localizedDataFileName = Join-Path $TestDrive ImportLocalizedDataAdditionalCommandsNotSupported.psd1
                    $null = New-Item -ItemType File -Path $localizedDataFileName -Force
                    Import-LocalizedData -SupportedCommand Add-Type -BaseDirectory $TestDrive -FileName ImportLocalizedDataAdditionalCommandsNotSupported
                }
            }
            catch
            {
                $expectedError = $_
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $expectedError.FullyQualifiedErrorId | Should -BeExactly "CannotDefineSupportedCommand,Microsoft.PowerShell.Commands.ImportLocalizedData"
        }
    }

    Describe "Where and Foreach operators should not allow unapproved types in constrained language" -Tags 'Feature','RequireAdminOnWindows' {

        BeforeAll {

            $script1 = @'
                $data = @(
                    @{
                        Node = "first"
                        Value1 = 1
                        Value2 = 2
                        first = $true
                    }
                    @{
                        Node = "second"
                        Value1 = 3
                        Value2 = 4
                        Second = $true
                    }
                    @{
                        Node = "third"
                        Value1 = 5
                        Value2 = 6
                        third = $true
                    }
                )

                $result = $data.where{$_.Node -eq "second"}
                Write-Output $result

                # Execute method in scriptblock of where operator, should throw in ConstrainedLanguage mode.
                $data.where{[system.io.path]::GetRandomFileName() -eq "Hello"}
'@

            $script2 = @'
                $data = @(
                    @{
                        Node = "first"
                        Value1 = 1
                        Value2 = 2
                        first = $true
                    }
                    @{
                        Node = "second"
                        Value1 = 3
                        Value2 = 4
                        Second = $true
                    }
                    @{
                        Node = "third"
                        Value1 = 5
                        Value2 = 6
                        third = $true
                    }
                )

                $result = $data.foreach('value1')
                Write-Output $result

                # Execute method in scriptblock of foreach operator, should throw in ConstrainedLanguage mode.
                $data.foreach{[system.io.path]::GetRandomFileName().Length}
'@

            $script3 = @'
            # Method call should throw error.
            (Get-Process powershell*).Foreach('GetHashCode')
'@

            $script4 = @'
            # Where method call should throw error.
            (get-process powershell).where{$_.GetType().FullName -match "process"}
'@

            $TestCasesForeach = @(
                @{testName = "Verify where statement with invalid method call in constrained language is disallowed"; script = $script1 }
                @{testName = "Verify foreach statement with invalid method call in constrained language is disallowed"; script = $script2 }
                @{testName = "Verify foreach statement with embedded method call in constrained language is disallowed"; script = $script3 }
                @{testName = "Verify where statement with embedded method call in constrained language is disallowed"; script = $script4 }
            )
        }

        It "<testName>" -TestCases $TestCasesForeach {

            param (
                [string] $script
            )

            try
            {
                $ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"
                & {
                    # Scriptblock must be created inside constrained language.
                    $sb = [scriptblock]::Create($script)
                    & sb
                }
                throw "No Exception!"
            }
            catch
            {
                $expectedError = $_
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $expectedError.FullyQualifiedErrorId | Should -BeExactly "MethodInvocationNotSupportedInConstrainedLanguage"
        }
    }

    Describe "ThreadJob Constrained Language Tests" -Tags 'Feature','RequireAdminOnWindows' {

        BeforeAll {

            $sb = { $ExecutionContext.SessionState.LanguageMode }
        }

        It "ThreadJob script must run in ConstrainedLanguage mode with system lock down" {

            try
            {
                $ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"
                Invoke-LanguageModeTestingSupportCmdlet -SetLockdownMode

                $results = Start-ThreadJob -ScriptBlock { $ExecutionContext.SessionState.LanguageMode } | Wait-Job | Receive-Job
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -RevertLockdownMode -EnableFullLanguageMode
            }

            $results | Should -BeExactly "ConstrainedLanguage"
        }

        It "ThreadJob script block using variable must run in ConstrainedLanguage mode with system lock down" {

            try
            {
                $ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"
                Invoke-LanguageModeTestingSupportCmdlet -SetLockdownMode

                $results = Start-ThreadJob -ScriptBlock { & $using:sb } | Wait-Job | Receive-Job
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -RevertLockdownMode -EnableFullLanguageMode
            }

            $results | Should -BeExactly "ConstrainedLanguage"
        }

        It "ThreadJob script block argument variable must run in ConstrainedLanguage mode with system lock down" {

            try
            {
                $ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"
                Invoke-LanguageModeTestingSupportCmdlet -SetLockdownMode

                $results = Start-ThreadJob -ScriptBlock { param ($sb) & $sb } -ArgumentList $sb | Wait-Job | Receive-Job
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -RevertLockdownMode -EnableFullLanguageMode
            }

            $results | Should -BeExactly "ConstrainedLanguage"
        }

        It "ThreadJob script block piped variable must run in ConstrainedLanguage mode with system lock down" {

            try
            {
                $ExecutionContext.SessionState.LanguageMode = "ConstrainedLanguage"
                Invoke-LanguageModeTestingSupportCmdlet -SetLockdownMode

                $results = $sb | Start-ThreadJob -ScriptBlock { $input | ForEach-Object { & $_ } } | Wait-Job | Receive-Job
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -RevertLockdownMode -EnableFullLanguageMode
            }

            $results | Should -BeExactly "ConstrainedLanguage"
        }
    }

    # End Describe blocks
}
finally
{
    if ($defaultParamValues -ne $null)
    {
        $Global:PSDefaultParameterValues = $defaultParamValues
    }
}
