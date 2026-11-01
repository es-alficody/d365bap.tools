<#
.SYNOPSIS
    Tests the discarded-output lint rule.

.DESCRIPTION
    Parses fixture scripts and checks that command and expression output is
    redirected to $null instead of being assigned to $null, piped to Out-Null,
    or cast to [void]. Non-output stream redirections are ignored.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
foreach ($script in @('Get-Ps1CommentGroup', 'Get-Ps1HelpSection', 'Get-Ps1Analysis', 'Get-Ps1NullEscapeDiagnostic')) {
	. "$PSScriptRoot/ps1-lint/internal/$script.ps1"
}
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('null-escape-rule-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixtureRoot -Force
$script:caseCount = 0

function Assert-NullEscape {
	param([string] $Label, [string] $Source, [int] $Expected = 0, [string[]] $ExpectedText = @(), [string] $FileName = 'Get-Fixture.ps1', [string] $Directory = 'd365bap.tools/functions')
	$folder = Join-Path $fixtureRoot $Directory
	$null = New-Item -ItemType Directory -Path $folder -Force
	$path = Join-Path $folder $FileName
	[IO.File]::WriteAllText($path, $Source.Replace("`r`n", "`n"))
	$analysis = Get-Ps1Analysis -Path $path
	$diagnostics = @(Get-Ps1NullEscapeDiagnostic -Analysis $analysis)
	if ($diagnostics.Count -ne $Expected) {
		throw "${Label}: expected $Expected diagnostics, got $($diagnostics.Count): $($diagnostics.Message -join ' ')"
	}
	$message = @($diagnostics | ForEach-Object { "$($_.RuleName) $($_.Message)" }) -join ' '
	foreach ($fragment in $ExpectedText) {
		if (-not $message.Contains($fragment)) { throw "${Label}: missing '$fragment' in '$message'" }
	}
	$script:caseCount++
}

$redirect = @'
function Get-Fixture {
    Invoke-RestMethod -Method Post -Uri $uri > $null
}
'@
Assert-NullEscape 'Output redirection' $redirect
Assert-NullEscape 'Redirect with verbose stream' ($redirect.Replace('> $null', '> $null 4> $null'))
Assert-NullEscape 'Verbose stream only' ($redirect.Replace('> $null', '4> $null'))
Assert-NullEscape 'Error stream only' ($redirect.Replace('> $null', '2> $null'))
Assert-NullEscape 'Warning stream only' ($redirect.Replace('> $null', '3> $null'))
Assert-NullEscape 'Information stream only' ($redirect.Replace('> $null', '6> $null'))
Assert-NullEscape 'All streams is not output only' ($redirect.Replace('> $null', '*> $null'))

Assert-NullEscape 'Command assigned to null' @'
function Get-Fixture {
    $null = Invoke-RestMethod -Method Post -Uri $uri
}
'@ 1 @('PSUseNullRedirectionForDiscardedOutput', 'Invoke-RestMethod', 'assigning')

Assert-NullEscape 'Parenthesized command assigned to null' @'
function Get-Fixture {
    $null = (Invoke-RestMethod -Method Post -Uri $uri)
}
'@ 1 @('Invoke-RestMethod', 'assigning')

Assert-NullEscape 'Command assigned to null in a loop' @'
function Get-Fixture {
    foreach ($path in $paths) {
        $null = New-Item -ItemType Directory -Path $path -Force
    }
}
'@ 1 @('New-Item', 'assigning')

Assert-NullEscape 'Method call assigned to null' @'
function Get-Fixture {
    $null = $list.Add($item)
}
'@ 1 @('expression', 'assigning')

Assert-NullEscape 'Static method call assigned to null' @'
function Get-Fixture {
    $null = [Reflection.Assembly]::LoadFrom($path)
}
'@ 1 @('expression', 'assigning')

Assert-NullEscape 'Property assigned to null is not output' @'
function Get-Fixture {
    $null = $_.Exception.Message
}
'@

Assert-NullEscape 'Constant assigned to null is not output' @'
function Get-Fixture {
    $null = 5
}
'@

Assert-NullEscape 'Command piped to Out-Null' @'
function Get-Fixture {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}
'@ 1 @('piping it to Out-Null', 'New-Item')

Assert-NullEscape 'Expression piped to Out-Null' @'
function Get-Fixture {
    $list.Add($item) | Out-Null
}
'@ 1 @('expression', 'piping it to Out-Null')

Assert-NullEscape 'Method call redirected to null' @'
function Get-Fixture {
    $list.Add($item) > $null
}
'@

Assert-NullEscape 'Static method call redirected to null' @'
function Get-Fixture {
    [Reflection.Assembly]::LoadFrom($path) > $null
}
'@

Assert-NullEscape 'Void cast expression' @'
function Get-Fixture {
    [void]$list.Add($item)
}
'@ 1 @('casting it to [void]')

Assert-NullEscape 'Void cast around a command' @'
function Get-Fixture {
    [void](Get-Thing)
}
'@ 1 @('casting it to [void]')

Assert-NullEscape 'Out-Null at the end of a longer pipeline' @'
function Get-Fixture {
    Get-Thing | Where-Object { $_ } | Out-Null
}
'@ 1 @('piping it to Out-Null')

Assert-NullEscape 'Three escapes in one file' @'
function Get-Fixture {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    $null = Invoke-RestMethod -Method Post -Uri $uri
    [void]$list.Add($item)
}
'@ -Expected 3

Assert-NullEscape 'Internal functions are checked' $redirect -Directory 'd365bap.tools/internal'
Assert-NullEscape 'Null assignment is checked internally' @'
function Get-Fixture {
    $null = New-Item -ItemType Directory -Path $path -Force
}
'@ -Directory 'd365bap.tools/internal' -Expected 1
Assert-NullEscape 'Outside the module' @'
function Get-Fixture {
    $null = New-Item -ItemType Directory -Path $path -Force
}
'@ -Directory 'build'
Assert-NullEscape 'Test files are never checked' @'
function Get-Fixture {
    $null = New-Item -ItemType Directory -Path $path -Force
}
'@ -FileName 'Get-Ps1NullEscapeRule.Tests.ps1'

$script:caseCount++
Write-Output "Null escape rule checks passed: $script:caseCount cases."
