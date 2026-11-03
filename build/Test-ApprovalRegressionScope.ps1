<#
.SYNOPSIS
    Decides whether the approval regression suite must run for a change set.

.DESCRIPTION
    Fails safe: the suite runs unless *every* changed path is proven not to be
    an input of the four approval test files or of Get-SignatureDelta.ps1.

    An empty, unreadable or unexpected change set also runs the suite. There is
    no allow-list of paths that must run; there is only a deny-list of paths that
    provably cannot change a verdict, so a new or unknown path always runs.

.PARAMETER Path
    Changed path, relative to the repository root, as reported by git. Repeat
    the parameter or pipe a list. Renames must be passed as both sides.

.PARAMETER FromStdin
    Read one changed path per line from standard input instead of -Path.

.PARAMETER ChangeSetComplete
    Set only when the caller is certain the list is complete. When absent the
    script still runs the suite if no path is supplied.

.EXAMPLE
    'd365bap.tools/functions/Get-Example.ps1' | ./build/Test-ApprovalRegressionScope.ps1
#>
[CmdletBinding()]
param(
	[Parameter(ValueFromPipeline = $true)]
	[string[]] $Path,
	[switch] $FromStdin,
	[switch] $ChangeSetComplete
)

begin {
	# Every entry is a path that cannot change the verdict of the approval
	# regression suite. Each class is justified in the #360 report; the parser and
	# the three gates are tested against fixtures and against the workflow files,
	# never against repository module, SDK, documentation or sample content.
	$colIrrelevantGlob = @(
		'd365bap.tools/*'
		'docs/*'
		'library/*'
		'learning/*'
		'wiki/*'
		'TestResults/*'
		'.devcontainer/*'
		'README.md'
		'LICENSE'
		'AGENTS.md'
		'install.ps1'
		'azure-pipelines.yml'
		'.gitignore'
		'.gitattributes'
	)
	$colSeen = [System.Collections.Generic.List[string]]::new()
}
process {
	foreach ($itemPath in @($Path)) {
		if (-not [string]::IsNullOrWhiteSpace($itemPath)) { $colSeen.Add($itemPath.Trim()) }
	}
}
end {
	if ($FromStdin) {
		while ($null -ne ($itemLine = [Console]::In.ReadLine())) {
			if (-not [string]::IsNullOrWhiteSpace($itemLine)) { $colSeen.Add($itemLine.Trim()) }
		}
	}

	$colRelevant = [System.Collections.Generic.List[string]]::new()
	foreach ($itemPath in $colSeen) {
		$itemNormalized = $itemPath -replace '\\', '/'
		if ($itemNormalized.StartsWith('/') -or $itemNormalized -match '^[A-Za-z]:') {
			# Unexpected absolute path: cannot reason about it, so run.
			$colRelevant.Add($itemPath)
			continue
		}
		$blnKnownIrrelevant = $false
		foreach ($itemGlob in $colIrrelevantGlob) {
			# Case-sensitive on purpose: a path that differs only in case from a
			# proven-irrelevant prefix is unknown input and therefore runs the suite.
			if ($itemNormalized -clike $itemGlob) { $blnKnownIrrelevant = $true; break }
		}
		if (-not $blnKnownIrrelevant) { $colRelevant.Add($itemPath) }
	}

	$blnRun = $true
	$strReason = ''
	if ($colSeen.Count -eq 0) {
		$strReason = 'No changed path was supplied, so the suite runs (fail-safe default).'
	} elseif (-not $ChangeSetComplete) {
		$strReason = 'Change set was not declared complete, so the suite runs (fail-safe default).'
	} elseif ($colRelevant.Count -gt 0) {
		$strReason = "Relevant inputs changed: $($colRelevant -join ', ')"
	} else {
		$blnRun = $false
		$strReason = "All $($colSeen.Count) changed path(s) are outside the approval regression input set."
	}

	$strRunValue = if ($blnRun) { 'true' } else { 'false' }
	if ($env:GITHUB_OUTPUT) {
		"run=$strRunValue" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
	}
	if ($env:GITHUB_STEP_SUMMARY) {
		@(
			'### Approval regression scope'
			"Decision: **$(if ($blnRun) { 'run the suite' } else { 'skip the suite' })**"
			''
			"$strReason"
			''
			"Changed path(s): $($colSeen.Count); relevant: $($colRelevant.Count)"
		) | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
	}
	Write-Output "run=$strRunValue"
	Write-Output $strReason
}
# measurement sample 1
