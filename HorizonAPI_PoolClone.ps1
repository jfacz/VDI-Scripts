<#
.SYNOPSIS
    Automates the creation of a new Omnissa Horizon Instant Clone VDI pool by duplicating an existing template pool.

.DESCRIPTION
    Creates a new Automated Instant Clone desktop pool by duplicating an existing pool using the Horizon REST API.
    The administrator selects the source pool and configures the new Pool ID, Display Name, and Naming Pattern.

.NOTES
    Author:         Jan Fara
    Last Update:    2026-08-15
#>

# ==============================================================================
# --- Script Parameters ---
# ==============================================================================
param (
    [Parameter(Mandatory=$false)] [string] $NewPoolId,
    [Parameter(Mandatory=$false)] [string] $NewPoolDisplayName,
    [Parameter(Mandatory=$false)] [string] $NewPoolNamingPattern
)

# ------------------------------------------------------------------------------
# --- Settings ---
# ------------------------------------------------------------------------------
$VAR = @{
 # Script Name
  ScriptName = "Horizon REST API Create VDI Pool (Clone)"
 # Script Path ($PSScriptRoot for CurrentPath)
  ScriptPath = $PSScriptRoot
 # --- LOG ---
 # LogFiles
  LogDir = "Logs"
  LogFileName = "Horizon_ClonePool_{0:yyyyMMdd}.txt"
  LogArchiveFiles = 12
}

# Horizon REST API vars
$API = @{
  Name = "IC22SWCS1"
  URIbase = "https://ic22swcs1.hop.int/rest"
  Username = "svc_adm"
  Domain = "HOP"
  SecCred = "sec_api_$($env:COMPUTERNAME)_$($env:USERNAME).txt"
  Token = $null
  AuthHeader = $null
}

# ------------------------------------------------------------------------------
# Initialization
# ------------------------------------------------------------------------------
$LogDir = Join-Path $VAR.ScriptPath $VAR.LogDir
$LogFile = (Join-Path $LogDir $VAR.LogFileName) -f (Get-Date)
$SecCredAPI = Join-Path $VAR.ScriptPath $API.SecCred
$DEBUG = $true

# ------------------------------------------------------------------------------
# Functions
# ------------------------------------------------------------------------------
# Import shared functions library
if(Test-Path "$PSScriptRoot\HorizonAPI_Fce.ps1"){
    . "$PSScriptRoot\HorizonAPI_Fce.ps1"
} else {
    Write-Host "ERROR: Shared functions library HorizonAPI_Fce.ps1 not found!"; break
}

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
# Local dir
if(!(Test-Path $LogDir -PathType Container)){ New-Item -Path $LogDir -ItemType Directory | out-null }
# Transcript Log - Start
if($Host.Name -match "ConsoleHost"){ Start-Transcript -Path $LogFile -append }

# ------------------------------------------------------------------------------
# Configurations
# ------------------------------------------------------------------------------
# Config certification and security policy
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$certPolicyCode = @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) { return true; }
    }
"@
if(-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type){ Add-Type -TypeDefinition $certPolicyCode }
[Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
#[System.Globalization.CultureInfo]::CurrentCulture = New-Object System.Globalization.CultureInfo("en-US")

# ------------------------------------------------------------------------------
# Security
# ------------------------------------------------------------------------------
if(($API.URIbase -like "") -or ($API.Username -like "") -or ($API.Domain -like "") -or ($API.SecCred -like "")){
    MsgFce "ERROR: Incomplete configuration of Security (API URIbase, API Username, API Domain or Credential Files)!" -Output error
    break
}

# Security API Credential File
if(!(Test-Path $SecCredAPI)){
    MsgFce "WARN: Credential file $($SecCredAPI) for API user '$($API.Username)' (Domain: $($API.Domain)) doesn't exist" -Output warn
    MsgFce "Please enter password for this account in the following dialog box (it will be saved using DPAPI for future use.):" -Output note
    try{
        Read-Host -AsSecureString | ConvertFrom-SecureString | Out-File $SecCredAPI -ErrorAction Stop
        MsgFce "INFO: The password was successfully saved to '$($SecCredAPI)'" -Output success
    } catch{
        MsgFce "ERROR: Failed to save the password $($_.Exception.Message)" -Output error
    }
}

# Load user password (DPAPI)
$SecAuthPwd = $null
if(Test-Path $SecCredAPI){
    MsgFce "INFO: Loading password (DPAPI) for API user '$($API.Username)'.."
    $SecAuthPwd = Get-Content $SecCredAPI | ConvertTo-SecureString -ErrorAction Stop
} else{
    MsgFce "WARN: Credential file '$($SecCredAPI)' for API user '$($API.Username)' doesn't exist or couldn't be decrypted (possibly created by another user)." -Output warn
}

# ------------------------------------------------------------------------------
# --- Main Execution ---
# ------------------------------------------------------------------------------
Clear-Host
$msg = "$($VAR.ScriptName) --- The beginning of the script --- [{0:yyyy-MM-dd HH:mm:ss}]" -f (Get-Date)
MsgFce $msg -Output note -LinesAfter 1

# REST API Login and set Token and AuthHeader
try{
    $API.Token = hAPIConnect -ApiURIbase $API.URIbase -username $API.Username -password $SecAuthPwd -domain $API.Domain
    $API.AuthHeader = hAPIGetAuthHeader -ApiToken $API.Token
    if($null -eq $API.Token){ MsgFce "ERROR: REST API access token is null" -Output warn } else{ MsgFce "Sucessfully connected to Horizon REST API '$($API.Name)'" -Output success -LinesAfter 1 }
} catch{
    MsgFce "Couldn't connect to Horizon REST API (URI: $($API.URIbase))! Error details: $($_.Exception.Message)" -Output error
    if($DEBUG){ $_.Exception }
    return
}

# List of All Instant Clones desktop pools
MsgFce "INFO: Fetching available VDI pools..."
$pools = hAPIGetDesktopPool -ApiURIbase $API.URIbase -ApiAuthHeader $API.AuthHeader
# Filter only Automated (Instant Clone) pools
$poolsIc = @($pools) | Where-Object { $_.type -eq "AUTOMATED" -and $_.source -eq "INSTANT_CLONE" -and $_.image_source -eq "VIRTUAL_CENTER" }
MsgFce "INFO: Getting detailed information for all ($($poolsIc.Count)) instant clone desktop pools..." -Output note
$poolsTb = @()

foreach($p in $poolsIc){
    # Fetch detailed info for each pool
    $pData = hAPIGetDesktopPoolDetail -Id $p.id -ApiURIbase $API.URIbase -ApiAuthHeader $API.AuthHeader
    # Instant Clone specification
    $pProvSet = $pData.provisioning_settings
    if($pProvSet){
        $vcId = $pData.vcenter_id
        $vmId = $pProvSet.parent_vm_id
        $snapId = if($null -ne $pProvSet.snapshot_id){ $pProvSet.snapshot_id } else{ $pProvSet.base_snapshot_id }
        # Resolve readable names from IDs
        $vmObj = hAPIGetBaseVmById -Id $vmId -vCenterId $vcId -ApiURIbase $API.URIbase -ApiAuthHeader $API.AuthHeader
        $snapObj = hAPIGetBaseVmSnapshotById -Id $snapId -vCenterId $vcId -BaseVmId $vmId -ApiURIbase $API.URIbase -ApiAuthHeader $API.AuthHeader
        # Extract provisioning status data and details
        $pProvData = $pData.provisioning_status_data
        $pProvOperation = $pProvData.instant_clone_operation
        $pProvOperationSettings = $pProvData.instant_clone_push_image_settings
        if($pProvOperationSettings.logoff_policy){
            $sTime = [DateTimeOffset]::FromUnixTimeMilliseconds($pProvOperationSettings.start_time).ToLocalTime().ToString("yyyyMMdd HH:mm:ss")
            $pProvOperation += " (start: $($sTime), $($pProvOperationSettings.logoff_policy))"
        }
        # table data row
        $row = [ordered] @{
            PoolName   = $p.name
            PoolId     = $p.id
            Enabled    = $pData.enabled
            ParentVM   = if($null -ne $vmObj){ $vmObj.name } else{ "Unknown ($vmId)" }
            ParentVMId = $vmId
            Snapshot   = if($null -ne $snapObj){ $snapObj.name } else{ "Unknown ($snapId)" }
            SnapshotId = $snapId
            vCenterId  = $vcId
            ImageState = if($null -ne $pProvData){ $pProvData.instant_clone_current_image_state } else{ "N/A" }
            Operation  = if($null -ne $pProvData){ $pProvOperation } else{ "N/A" }
        }
        $poolsTb += [pscustomobject] $row
    }
}

MsgFce "LIST of instant clones desktop pool:" -Output verbose -LinesBefore 1 -LinesAfter 1
if($poolsTb.Count){
    $poolsTbMsg = ($poolsTb | Select-Object PoolName, Enabled, ParentVM, Snapshot, ImageState, Operation | Format-Table -AutoSize | Out-String).Trim()
    MsgFce $poolsTbMsg -LinesAfter 1  
} else{
    MsgFce "WARN: No Instant Clones Virtual desktop Pools found." -Output warn
}

# Menu for selecting pool as source template
$mTitle = "Select VDI pool as source template for now (clone) VDI pool"
$mOpts = @("Exit") + ($poolsTb | ForEach-Object { "$($_.PoolName)" })
$mSelPoolTempl = MenuSimple -MenuItems $mOpts -Title $mTitle -StartFrom 0
if($mSelPoolTempl -like "Exit"){
    MsgFce "WARN: Terminated by user (exit)" -Output warn
    break
}
# Extract selected source pool
$PoolTempl = $poolsTb | Where-Object { "$($_.PoolName)" -eq $mSelPoolTempl }
MsgFce "Selected VDI pool as template: $($PoolTempl.PoolName)" -Output success

# Fetch full details of the template pool
MsgFce "INFO: Loading source VDI pool '$($PoolTempl.PoolName)' details..."
$PoolTemplData = hAPIGetDesktopPoolDetail -Id $PoolTempl.PoolId -ApiURIbase $API.URIbase -ApiAuthHeader $API.AuthHeader
if($null -eq $PoolTemplData){
    MsgFce "ERR: Failed to load source VDI pool details => can't proceed!" -Output error
    break
}

# Input New Pool Data (Interactive)
MsgFce "New Desktop Pool configuration" -Output Verbose -LinesBefore 1
# Pool Name (ID)
$nPoolId = $NewPoolId
while($true){
    if([string]::IsNullOrWhiteSpace($nPoolId)){
        $nPoolId = Read-Host "Enter New Pool ID (e.g., IC22DW99-XYZ)"
    }
    if([string]::IsNullOrWhiteSpace($nPoolId)){
        MsgFce "ERROR: Pool ID cannot be empty! Please enter a valid ID." -Output warn
    } elseif($pools.name -contains $nPoolId){
        MsgFce "ERROR: Pool with ID '$nPoolId' already exists in Horizon! Please choose a unique ID." -Output warn
        $nPoolId = $null # Reset to prompt again
    } else {
        break # ID is valid and unique
    }
}
# Pool Display Name
$nPoolDisplayName = $NewPoolDisplayName
if([string]::IsNullOrWhiteSpace($nPoolDisplayName)){
    $nPoolDisplayName = Read-Host "Enter Display Name (e.g., HOP XYZ (IC22DW99))"
    if([string]::IsNullOrWhiteSpace($nPoolDisplayName)){ $nPoolDisplayName = $nPoolId }
}
# Pool Naming Pattern
$nPoolNamingPattern = $NewPoolNamingPattern
if([string]::IsNullOrWhiteSpace($nPoolNamingPattern)){
    #$nPoolNamingPattern = Read-Host "Enter Machine Naming Pattern (e.g., IC22DW99-XYZ{n:fixed=2})"
    if([string]::IsNullOrWhiteSpace($nPoolNamingPattern)){ $nPoolNamingPattern = "$($nPoolId){n:fixed=2}" }
}
while($true){
    if([string]::IsNullOrWhiteSpace($nPoolNamingPattern)){
        $nPoolNamingPattern = Read-Host "Enter Machine Naming Pattern (e.g., IC22DW99-XYZ{n:fixed=2}, default: $($nPoolId){n:fixed=2})"
        if([string]::IsNullOrWhiteSpace($nPoolNamingPattern)){ $nPoolNamingPattern = "$($nPoolId){n:fixed=2}" }
    }
    # Predictive length calculation for Horizon placeholders
    $predictedName = $nPoolNamingPattern
    if($nPoolNamingPattern -match '\{n:fixed=(\d+)\}'){
        $digits = [int]$matches[1]
        $predictedName = $nPoolNamingPattern -replace '\{n:fixed=\d+\}', ('X' * $digits)
    } elseif($nPoolNamingPattern -match '\{n\}'){
        $predictedName = $nPoolNamingPattern -replace '\{n\}', 'X'
    }
    if($predictedName.Length -le 15){
        break
    } else {
        MsgFce "ERROR: Resulting computer name '$($predictedName)' would be too long ($($predictedName.Length) chars)! Max length for Active Directory is 15 characters." -Output warn
        $nPoolNamingPattern = $null # Reset to force Read-Host in next loop iteration
    }
}

$mTitle = "Continue with cloning of VDI pool '$($PoolTempl.PoolName)' to new one '$($nPoolId)' $([Environment]::NewLine)(DisplayName: '$($nPoolDisplayName)', Naming Pattern: '$($nPoolNamingPattern)')?"
$mOpts = @("No", "Yes")
$mSel = MenuSimple -MenuItems $mOpts -Title $mTitle -StartFrom 0
if($mSel -eq "Yes"){
    # Prepare Body for API
    $body = @{
        name                = $nPoolId
        display_name        = $nPoolDisplayName
        description         = "Cloned from $($PoolTempl.PoolName) via API Script on $(Get-Date)"
        naming_method       = "PATTERN"
        # others cloned from source pool
        access_group_id     = $PoolTemplData.access_group_id
        enabled             = $PoolTemplData.enabled
        session_type        = $PoolTemplData.session_type
        type                = $PoolTemplData.type
        source              = $PoolTemplData.source
        image_source        = $PoolTemplData.image_source
        vcenter_id          = $PoolTemplData.vcenter_id
        user_assignment     = $PoolTemplData.user_assignment
        session_settings          = $PoolTemplData.session_settings
        display_protocol_settings = $PoolTemplData.display_protocol_settings
        pattern_naming_settings   = $PoolTemplData.pattern_naming_settings
        provisioning_settings     = $PoolTemplData.provisioning_settings
        storage_settings          = $PoolTemplData.storage_settings
        nics                      = $PoolTemplData.nics
        customization_settings    = $PoolTemplData.customization_settings
    }
    # Update the naming pattern
    $body.pattern_naming_settings.naming_pattern = $nPoolNamingPattern
    # Body JSON
    $bodyJson = $body | ConvertTo-Json -Depth 10

    # Create Pool
    MsgFce "ACTION: Creating new pool '$($nPoolId)'..." -Output verbose
    $uri = hAPIBuildUri -ApiPath "inventory/v11/desktop-pools" -ApiURIbase $API.URIbase
    try{
        Invoke-RestMethod -Method Post -Uri $uri -Headers $API.AuthHeader -Body $bodyJson -ContentType "application/json"
        MsgFce "SUCCESS: Pool '$($nPoolId)' was created" -Output success
    } catch{
        MsgFce "ERROR during Pool Creation process: $($_.Exception.Message)" -Output error
        if($DEBUG -and ($null -ne $_.Exception.Response)){
            $er = $(New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd()
            MsgFce "ERR DETAIL: $($er)" -Output error
        }
    }
} else{
    MsgFce "INFO: Cloning of VDI pool canceled" -Output verbose
}


# --- Logging maintenance ---
$LogFiles = Get-ChildItem $LogDir | Where-Object {-not $_.PSIsContainer}
if($LogFiles.Count -gt $VAR.LogArchiveFiles){
    MsgFce "There is currently $($LogFiles.Count)  files In log archive folder '$($LogDir)' - it's more than set archive limit $($VAR.LogArchiveFiles). The oldest files will be deleted." -LinesBefore 1
    $LogFiles | Sort-Object LastWriteTime | Select-Object -First ($LogFiles.Count-$VAR.LogArchiveFiles) | Remove-Item
}

# End
$msg = "$($VAR.ScriptName) --- End of the script --- [{0:yyyy-MM-dd HH:mm:ss}]" -f (Get-Date)
MsgFce $msg -Output note -LinesBefore 1

# Transcript Log - Stop
if($Host.Name -match "ConsoleHost"){ Stop-Transcript | out-null }

# Horizon API Logout
hAPIDisconnect -ApiURIbase $API.URIbase -ApiToken $API.Token