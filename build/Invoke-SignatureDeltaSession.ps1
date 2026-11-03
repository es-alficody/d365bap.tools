<#
.SYNOPSIS
    Runs Get-SignatureDelta.ps1 once per request inside a single pwsh process.

.DESCRIPTION
    Keeps a real subprocess and the real parser, and drops only the per-request
    PowerShell start-up cost. Each request is a tab-separated
    "baseRef<TAB>headRef" line on standard input. Each response is one line,
    "OK <base64 json>" or "ERR <base64 message>", written and flushed
    immediately so the caller can request the next comparison synchronously.

    A request that throws is reported as ERR; the process stays alive so the
    caller can continue asserting on the failure. A request that crashes the
    process is not swallowed: the caller sees end of stream and fails the test.

.PARAMETER ScriptPath
    Path to Get-SignatureDelta.ps1.
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)]
	[ValidateNotNullOrEmpty()]
	[string] $ScriptPath
)

$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$stdin = [Console]::In
$stdout = [Console]::Out
while ($null -ne ($itemLine = $stdin.ReadLine())) {
	if ([string]::IsNullOrWhiteSpace($itemLine)) { continue }
	$colPart = $itemLine.Split("`t")
	if ($colPart.Count -ne 2) {
		$strPayload = [Convert]::ToBase64String($utf8.GetBytes('Malformed session request'))
		$stdout.WriteLine("ERR $strPayload")
		$stdout.Flush()
		continue
	}
	try {
		# A real invocation of the real script: parameters, git batch process,
		# parsing and fail-closed validation all run exactly as in production.
		$strJson = (& $ScriptPath -BaseRef $colPart[0] -HeadRef $colPart[1]) -join "`n"
		$strPayload = [Convert]::ToBase64String($utf8.GetBytes($strJson))
		$stdout.WriteLine("OK $strPayload")
	} catch {
		$strPayload = [Convert]::ToBase64String($utf8.GetBytes($_.Exception.Message))
		$stdout.WriteLine("ERR $strPayload")
	}
	$stdout.Flush()
}
