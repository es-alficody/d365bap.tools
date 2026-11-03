$scbPpacRbacRoles = {
	$pathMisc = Get-PSFConfigValue -FullName "d365bap.tools.internal.misc.path"

	$rbacRoles = Get-Content `
		-Path "$pathMisc\Ppac.Rbac.Roles.json" `
		-Raw | ConvertFrom-Json

	$rbacRoles.roleDefinitionName | Sort-Object
}

Register-PSFTeppScriptblock `
	-Name "d365bap.tools.tepp.ppac.rbac.roles" `
	-ScriptBlock $scbPpacRbacRoles `
	-Mode Simple
#region Baseline measurement marker: comment only, no behaviour change.

#endregion Baseline measurement marker: comment only, no behaviour change.
