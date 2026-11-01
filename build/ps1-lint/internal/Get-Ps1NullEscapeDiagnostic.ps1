function Get-Ps1NullEscapeDiagnostic {
	param([hashtable] $Analysis)
	$Path = $Analysis.Path

	$normalized = $Path -replace '\\', '/'
	if ($normalized -notmatch '/d365bap\.tools/(functions|internal)/') { return }
	if ([IO.Path]::GetFileName($Path) -like '*Tests.ps1') { return }

	$ast = $Analysis.Ast

	foreach ($assignment in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$null' }, $true)) {
		$command = $assignment.Right.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $false)
		$invocation = $assignment.Right.Find({ param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] }, $false)

		$message = if ($null -ne $command) {
			'Redirect the command output to $null instead of assigning it: ' + $command.GetCommandName() + ' ... > $null.'
		}
		elseif ($null -ne $invocation) {
			'Redirect the expression output to $null instead of assigning it.'
		}
		else { continue }

		[pscustomobject]@{
			RuleName   = 'PSUseNullRedirectionForDiscardedOutput'
			Severity   = 'Error'
			ScriptName = [IO.Path]::GetFileName($Path)
			Line       = $assignment.Extent.StartLineNumber
			Column     = $assignment.Extent.StartColumnNumber
			Message    = $message
		}
	}

	foreach ($command in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Out-Null' }, $true)) {
		$pipeline = $command.Parent
		if ($pipeline -isnot [Management.Automation.Language.PipelineAst]) { continue }

		$elements = @($pipeline.PipelineElements)
		if ([Array]::IndexOf($elements, $command) -ne $elements.Count - 1) { continue }

		$message = if ($elements[0] -is [Management.Automation.Language.CommandAst]) {
			'Redirect the command output to $null instead of piping it to Out-Null: ' + $elements[0].GetCommandName() + ' ... > $null.'
		}
		else {
			'Redirect the expression output to $null instead of piping it to Out-Null.'
		}

		[pscustomobject]@{
			RuleName   = 'PSUseNullRedirectionForDiscardedOutput'
			Severity   = 'Error'
			ScriptName = [IO.Path]::GetFileName($Path)
			Line       = $command.Extent.StartLineNumber
			Column     = $command.Extent.StartColumnNumber
			Message    = $message
		}
	}

	foreach ($cast in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.ConvertExpressionAst] -and $node.Type.TypeName.Name -eq 'void' }, $true)) {
		[pscustomobject]@{
			RuleName   = 'PSUseNullRedirectionForDiscardedOutput'
			Severity   = 'Error'
			ScriptName = [IO.Path]::GetFileName($Path)
			Line       = $cast.Extent.StartLineNumber
			Column     = $cast.Extent.StartColumnNumber
			Message    = 'Redirect the expression output to $null instead of casting it to [void].'
		}
	}
}
