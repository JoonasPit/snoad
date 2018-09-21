﻿<#
.SYNOPSIS

Uses Active Directory (AD) as a source for Snowflake users, roles and role memberships. This is designed for 
deployments where Okta is used for SSO in conjunction with AD.

.DESCRIPTION

Using an Active Directory Organisational Unit (OU) as a source, the script retrieves all security groups 
within that OU, along with all users (including those within nested groups). For this reason, the script 
must be ran on a domain-connected Windows machine.

The list of all possible users is checked against Snowflake to ensure they all exist. If any are missing, 
they are either created or an error is raised, depending on the value of the createAnyMissingUsers parameter.

For each security group immediately within the OU, a role in Snowflake is matched or created and all 
Snowflake users are granted it. Any users who have subsequently been removed from the AD group will be revoked
from the corresponding role.

If disableRemovedUsers is set to $true, any SSO-based Snowflake users (i.e. those without Snowflake passwords)
will be disabled if they aren't part of any of the AD groups.

.PARAMETER snowflakeAccount

The name of the snowflake account

.PARAMETER snowflakeUser

The snowflake user account to use (password must be supplied using the SNOWSQL_PWD environment variable)

.PARAMETER snowflakeRole

The snowflake role to use

.PARAMETER snowflakeRegion

The region of the snowflake account

.PARAMETER ouIdentity

The distinguished name of the Active Directory OU to retrieve the list of security groups from.

.PARAMETER loginNameADAttribute

The Active Directory user attribute to use as the Snowflake login name, defaults to 'mail'

.PARAMETER createAnyMissingUsers

When set to $true (the default), if any Active Directory users listed under the AD security groups do
not exist in Snowflake, they will be automatically created.

When set to $false, all relevant users must be created in Snowflake prior to running 
this script .

.PARAMETER disableRemovedUsers

When set to $true, any Snowflake SSO users who do not appear under any of the Active Directory security
groups will be disabled in Snowflake.

When set to $false (the default), they will be left alone (though they will still be revoked from all 
AD-based Snowflake roles)

.PARAMETER rolePrefix

If specified, includes only security groups within the OU that begin with this string

.PARAMETER removeRolePrefix

If set to true, removes the value specified in rolePrefix from the beginning of the string. 
For example, if specifed a rolePrefix of 'snowflake-role-' and also set this parameter to $true, 
an AD group named 'snowflake-role-analyst' becomes the snowflake role 'analyst'.

.PARAMETER WhatIf

A testing/trust-building parameter. If specified, only outputs the SQL script to the terminal and doesn't run it.

.EXAMPLE

.\snoad.ps1 -snowflakeAccount 'ly12345' -snowflakeUser 'usersync' -snowflakeRole 'ACCOUNTADMIN' -snowflakeRegion 'ap-southeast-2' -ouIdentity 'OU=AsiaPacific,OU=Sales,OU=UserAccounts,DC=FABRIKAM,DC=COM' -createAnyMissingUsers $true

.NOTES

You must have snowsql installed and on your path prior to running this function.

Does not incur compute costs as user account administration does not run in a warehouse.

You must provide the Snowflake password in the environment variable SNOWSQL_PWD.

#>
param(
    [String][ValidateNotNullOrEmpty()]$snowflakeAccount='ap-southeast-2',
    [String][ValidateNotNullOrEmpty()]$snowflakeUser,
    [String][ValidateNotNullOrEmpty()]$snowflakeRole,
    [String][ValidateNotNullOrEmpty()]$snowflakeRegion,
    [String][ValidateNotNullOrEmpty()]$ouIdentity,
    [String]$loginNameADAttribute='mail',
    [Boolean]$createAnyMissingUsers=$True,
    [Boolean]$disableRemovedUsers=$True,
    [String]$rolePrefix,
    [Boolean]$removeRolePrefix=$False,
    [switch]$WhatIf)

$ErrorActionPreference = 'Stop'
$sqlStatement=""

write-host 'Importing Active Directory module'
Import-Module ActiveDirectory

if ($env:SNOWSQL_PWD -eq $null){
    throw "SNOWSQL_PWD environment variable not defined"
}

write-host "Retrieving list of current snowflake users"
$currentSnowflakeUsers = snowsql -a $snowflakeAccount -u $snowflakeUser -r $snowflakeRole --region $snowflakeRegion -q 'show users' -o exit_on_error=true -o output_format=csv -o friendly=false -o timing=false | convertfrom-csv
# Only include those without passwords (SSO users)
$currentSnowflakeUserNames = $currentSnowflakeUsers | where-object {$_.has_password -eq 'false'} | %{$_.name}

write-host "Retrieving AD security groups in OU $ouIdentity"
$roleMappings=@{}
$allGroups=Get-ADGroup -SearchBase $ouIdentity -filter {GroupCategory -eq "Security"}
$groupsMatchingRolePrefix = $allGroups
if ($rolePrefix -ne $null){
  $groupsMatchingRolePrefix = $allGroups | Where-Object {$_.Name.StartsWith($rolePrefix)}
}
$groupsMatchingRolePrefix | % {
  $roleName = $_.Name
  if ($removeRolePrefix){
    $roleNameNew = $roleName -replace "^$rolePrefix",""
    write-host "Removing role prefix from $roleName, yielding $roleNameNew"
    $roleName = $roleNameNew
  }
  write-host "Fetching users in group $roleName whose accounts aren't disabled"
  $roleMappings[$roleName] = $_ | Get-ADGroupMember -Recursive | select samaccountname | %{(Get-ADUser $_.samaccountname -Properties $loginNameADAttribute,Enabled | where-object {$_.($loginNameADAttribute) -ne $null -and $_.Enabled -eq $true}).($loginNameADAttribute)}
}

$allUsersInRoleMappings=$roleMappings.Keys |% {$roleMappings[$_]} | Select-Object -Unique | sort

$missingSnowflakeUsers=$allUsersInRoleMappings | Where-Object {$_ -notin $currentSnowflakeUserNames}
$superfluousSnowflakeUsers=$currentSnowflakeUserNames | Where-Object {$_ -notin $allUsersInRoleMappings}

$addUserSqlTemplate=@"
CREATE USER \"{0}\" LOGIN_NAME=\"{0}\" MUST_CHANGE_PASSWORD=FALSE;`r`n
"@

if ($missingSnowflakeUsers.Length -gt 0){
  if ($createAnyMissingUsers){
    write-host "Adding $($missingSnowflakeUsers.Length) missing users"
    $addUserSql=""
    $missingSnowflakeUsers | %{
      $sqlStatement = $sqlStatement + ($addUserSqlTemplate -f $_)
    }
  }else{
    throw "The following users are missing from Snowflake: $missingSnowflakeUsers"
  }
}

$disableUserSqlTemplate=@"
ALTER USER \"{0}\" SET DISABLED=TRUE;`r`n
"@

if ($superfluousSnowflakeUsers.Length -gt 0 -and $disableRemovedUsers){
  write-host "Disabling $($superfluousSnowflakeUsers.Length) users as they have no roles mapped in AD"
  $superfluousSnowflakeUsers | %{
    $sqlStatement = $sqlStatement + ($disableUserSqlTemplate -f $_)
  }
}

write-host "Retrieving list of current snowflake roles"
$currentSnowflakeRoles = snowsql -a $snowflakeAccount -u $snowflakeUser -r $snowflakeRole --region $snowflakeRegion -q 'show roles' -o exit_on_error=true -o output_format=csv -o friendly=false -o timing=false | convertfrom-csv

write-host "Checking membership of current roles"

$showGrantsSqlTemplate=@"
SHOW GRANTS OF ROLE \"{0}\";`r`n
"@
$showGrantsSql=""
$currentSnowflakeRoles | %{
  $showGrantsSql = $showGrantsSql + ($showGrantsSqlTemplate -f $_.name)
}
$currentSnowflakeRoleGrants = snowsql -a $snowflakeAccount -u $snowflakeUser -r $snowflakeRole --region $snowflakeRegion -q $showGrantsSql -o exit_on_error=true -o output_format=csv -o friendly=false -o timing=false | convertfrom-csv
$currentSnowflakeRoleGrants = $currentSnowflakeRoleGrants | Where-Object {$_.created_on -ne 'created_on'} # multiple record sets returned and flattened to CSV, remove the "header" rows

$createRoleSqlTemplate=@"
CREATE ROLE \"{0}\";`r`n
"@

$grantRoleSqlTemplate=@"
GRANT ROLE \"{0}\" TO USER \"{1}\";`r`n
"@

$revokeRoleSqlTemplate=@"
REVOKE ROLE \"{0}\" FROM USER \"{1}\";`r`n
"@

# ensure that all users, roles and grants defined in AD exist in snowflake
$roleMappings.Keys | % {
  $roleName = $_
  write-host "Checking role $roleName exists in Snowflake"
  if (($currentSnowflakeRoles | Where-Object {$_.name -eq $roleName}) -eq $null){
    write-host "Role does not exist, creating"
    $sqlStatement = $sqlStatement + ($createRoleSqlTemplate -f $roleName)
  }
  write-host "Checking role $roleName has the appropriate members"
  $currentRoleGrantees = $currentSnowflakeRoleGrants | Where-Object {$_.role -eq $roleName -and $_.grantee_name -like '*@*'} | %{$_.grantee_name}
  $missingSnowflakeGrantees = $roleMappings[$roleName] | Where-Object {$_ -ne $null -and $_ -notin $currentRoleGrantees}
  $superfluousSnowflakeGrantees = $currentRoleGrantees | Where-Object {$_ -ne $null -and $_ -notin $roleMappings[$roleName]}
  write-host "Missing grantees: $missingSnowflakeGrantees"
  write-host "Superfluous grantees: $superfluousSnowflakeGrantees"
  $missingSnowflakeGrantees | %{
    $sqlStatement = $sqlStatement + ($grantRoleSqlTemplate -f $roleName,$_)
  }
  $superfluousSnowflakeGrantees | %{
    $sqlStatement = $sqlStatement + ($revokeRoleSqlTemplate -f $roleName,$_)
  }
}


if ($sqlStatement.Length -gt 0){
  $sqlStatement = "BEGIN TRANSACTION;`r`n{0}COMMIT;" -f $sqlStatement
  If ($WhatIf){
    write-host "Without the -WhatIf flag, the script will execute the following SQL Statement: `r`n`r`n$sqlStatement"
  }else{
    write-host "Executing SQL statement:`r`n $sqlStatement"
    snowsql -a $snowflakeAccount -u $snowflakeUser -r $snowflakeRole --region $snowflakeRegion -q $sqlStatement -o exit_on_error=true -o output_format=csv -o timing=false -o log_level=DEBUG
  }
}else{
  write-host "No changes required"
}

