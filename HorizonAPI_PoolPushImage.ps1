<#
.SYNOPSIS
    Schedules a Push Image operation for Omnissa Horizon Instant Clone desktop pools.

.DESCRIPTION
    This script leverages the Horizon REST API to update the golden image (Parent VM) and snapshot for one or multiple Instant Clone desktop pools.

.NOTES
    Author:         Jan Fara
    Last Update:    2026-08-15
#>

# ==============================================================================
# --- Script Parameters ---
# ==============================================================================
param (
    [Parameter(Mandatory=$false)] [string] $PoolName,
    [Parameter(Mandatory=$false)] [string] $ParentVMName,
    [Parameter(Mandatory=$false)] [string] $SnapshotName,
    [Parameter(Mandatory=$false)] [Nullable [DateTime]] $ScheduleTime = $(Get-Date),
    [Parameter(Mandatory=$false)] [ValidateSet("FORCE_LOGOFF", "WAIT_FOR_LOGOFF")] [string] $LogoffPolicy = "WAIT_FOR_LOGOFF"
)

# ------------------------------------------------------------------------------
# --- Settings ---
# ------------------------------------------------------------------------------
$VAR = @{
 # Script Name
  ScriptName = "Horizon REST API Push Image Task"
 # Script Path ($PSScriptRoot for CurrentPath)
  ScriptPath = $PSScriptRoot
 # Update/Push of all VDI pools - delay in minutes between pools
  UpdateAllDelay = 6
 # --- LOG ---
 # LogFiles
  LogDir = "Logs"
  LogFileName = "Horizon_PoolPushImage_{0:yyyyMMdd}.txt"
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

# Switch var to update pool action
$updateVdiPool = $true

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
            PoolName     = $p.name
            PoolId       = $p.id
            Enabled      = $pData.enabled
            Provisioning = $pData.enable_provisioning
            ParentVM     = if($null -ne $vmObj){ $vmObj.name } else{ "Unknown ($vmId)" }
            ParentVMId   = $vmId
            Snapshot     = if($null -ne $snapObj){ $snapObj.name } else{ "Unknown ($snapId)" }
            SnapshotId   = $snapId
            vCenterId    = $vcId
            ImageState   = if($null -ne $pProvData){ $pProvData.instant_clone_current_image_state } else{ "N/A" }
            Operation    = if($null -ne $pProvData){ $pProvOperation } else{ "N/A" }
        }
        $poolsTb += [pscustomobject] $row
    }
}

MsgFce "LIST of all instant clones desktop pool:" -Output verbose -LinesBefore 1 -LinesAfter 1
if($poolsTb.Count){
    $poolsTbMsg = ($poolsTb | Select-Object PoolName, Enabled, Provisioning, ParentVM, Snapshot, ImageState, Operation | Format-Table -AutoSize | Out-String).Trim()
    MsgFce $poolsTbMsg -LinesAfter 1  
} else{
    MsgFce "WARN: No Instant Clones Virtual desktop Pools found." -Output warn
    $updateVdiPool = $false
}

# if all necessary script params are ready
if($PoolName -and $ParentVMName -and $SnapshotName){
    # 1. Get Desktop pool
    MsgFce "INFO: Getting Horizon Desktop VDI Pool '$($PoolName)'..."
    $pool = hAPIGetDesktopPool -FilterValue $PoolName -ApiURIbase $API.URIbase -ApiAuthHeader $API.AuthHeader
    if($null -ne $pool -and $null -ne $pool.id){
        MsgFce "OK (Desktop Pool ID: $($pool.id))" -Output note
    } else{
        MsgFce "Desktop pool not found or multiple items found => can't proceed!" -Output warn
        $updateVdiPool = $false
    }
    # 2. Get vCenter
    MsgFce "INFO: Getting Desktop Pool Virtual Center..."
    $vCenter = hAPIGetVCenter -FilterValue $pool.vcenter_id -FilterName "id" -ApiURIbase $API.URIbase -ApiAuthHeader $API.AuthHeader
    if($null -ne $vCenter -and $null -ne $vCenter.id){
        MsgFce "OK (vCenter ID: $($vCenter.id))" -Output note
    } else{
        MsgFce "vCenter not found (searched by id '$($pool.vcenter_id)') => can't proceed!" -Output warn
        $updateVdiPool = $false
    }
    # 3. Get Parent VM (Golden Image)
    MsgFce "INFO: Getting Parent VM (Golden Image) '$($ParentVMName)'..."
    $golden = if($updateVdiPool){ hAPIGetBaseVm -FilterValue $ParentVMName -vCenterId $vCenter.id -ApiURIbase $API.URIbase -ApiAuthHeader $API.AuthHeader } else { $null } 
    if($null -ne $golden -and $null -ne $golden.id){
        MsgFce "OK (Parent VM ID: $($golden.id))" -Output note
    } else{
        MsgFce "Parent VM not found or multiple items found => can't proceed!" -Output warn
        $updateVdiPool = $false
    }
    # 4. Get Parent VM Snapsahots
    MsgFce "INFO: Getting snapshot '$($SnapshotName)'..."
    $snapshot = if($updateVdiPool){ hAPIGetBaseVmSnapshot -FilterValue $SnapshotName -vCenterId $vCenter.id -BaseVmId $golden.id -ApiURIbase $API.URIbase -ApiAuthHeader $API.AuthHeader } else { $null } 
    if($null -ne $snapshot -and $null -ne $snapshot.id){
        MsgFce "OK (Parent VM Snapshot ID: $($snapshot.id))" -Output note
    } else{
        MsgFce "Parent VM snapshot not found or multiple items found => can't proceed!" -Output warn
        $updateVdiPool = $false
    }
    # Update/Push VDI pool task
    if($updateVdiPool){
        $mTitle = "Continue with update/push of VDI pool '$($PoolName)' (GI: '$($ParentVMName)', snapshot: '$($SnapshotName)')?"
        $mSchtime = "{0:yyyy-MM-dd HH:mm:ss}" -f $ScheduleTime 
        $mOpts = @("No", "Yes ($($mSchtime))", "Yes (now +10min)", "Yes (now +20min)", "Yes (now +30min)", "Yes (now +40min)", "Yes (now +50min)", "Yes (now +60min)")
        $mSel = MenuSimple -MenuItems $mOpts -Title $mTitle
        if($mSel -like "Yes*"){
            MsgFce "ACTION: Scheduling Push Image for pool '$($PoolName)'" -Output verbose
            # Schtask StartTime
            if($mSel -match 'now \+(\d+)min'){
                $minutes = [int] $matches[1]
                $start_time = (Get-Date).AddMinutes($minutes)
            } else{
                $start_time = $ScheduleTime
            }
            $start_time_unix = [DateTimeOffset]::new($start_time.ToUniversalTime()).ToUnixTimeMilliseconds()
            $body = @{
                parent_vm_id = $golden.id
                snapshot_id  = $snapshot.id
                logoff_policy = $LogoffPolicy
                start_time    = $start_time_unix
                stop_on_first_error = $true
            } | ConvertTo-Json
            # Uri for push image
            $uri = hAPIBuildUri -ApiPath "inventory/v1/desktop-pools/$($pool.id)/action/schedule-push-image" -ApiURIbase $API.URIbase
            try{
                $push = Invoke-RestMethod -Method Post -Uri $uri -ContentType "application/json" -Body $body -Headers $API.AuthHeader
                if($DEBUG){ $push }
                MsgFce ("SUCCESS: Push Image has been scheduled. Start time: {0:yyyy-MM-dd HH:mm:ss}" -f $start_time) -Output success
            } catch{
                MsgFce "ERROR during Push Image process: $($_.Exception.Message)" -Output error
                if($DEBUG -and ($null -ne $_.Exception.Response)){
                    $er = $(New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd()
                    MsgFce "ERR DETAIL: $($er)" -Output error
                }
            }
        } else{
            MsgFce "INFO: Update/push of VDI pool skipped (not selected Yes)" -Output verbose
        }
    } else{
        MsgFce "WARN: Conditions for VDI pool update/push not met => no action" -Output warn -LinesBefore 1
    }
} else{
    # Menu for selecting pool as source template
    $mTitle = "Select VDI pool as template for other pools (Pool Parent VM / Golden Image and Snapshot)"
    $mOpts = @("Exit") + ($poolsTb | ForEach-Object { "$($_.PoolName) ($($_.ParentVM) - $($_.Snapshot))" })
    $mSelPoolTempl = MenuSimple -MenuItems $mOpts -Title $mTitle -StartFrom 0
    if($mSelPoolTempl -like "Exit"){
        MsgFce "WARN: Terminated by user (exit)" -Output warn
        break
    }
    # Extract selected source pool
    $PoolTempl = $poolsTb | Where-Object { "$($_.PoolName) ($($_.ParentVM) - $($_.Snapshot))" -eq $mSelPoolTempl }
    MsgFce "Selected VDI pool as template: $($PoolTempl.PoolName)" -Output success

    # Menu for select targets
    $mTitle = "Select target VDI pool for update/push"
    $mOpts = @("Cancel", "Update ALL other IC pools", "Update specific pool only")
    $mSelTargetMode = MenuSimple -MenuItems $mOpts -Title $mTitle -StartFrom 0
    if($mSelTargetMode -eq "Cancel"){
        MsgFce "WARN: Terminated by user (cancel)" -Output warn
        break
    }
    # Target VDI Pool(s)
    $targetPools = @()
    if($mSelTargetMode -match "ALL"){
        $targetPools = $poolsTb | Where-Object { $_.PoolName -ne $PoolTempl.PoolName }
    } else {
        $mTitle = "Select one VDI pool for update/push"
        $mOpts = ($poolsTb | Where-Object { $_.PoolName -ne $PoolTempl.PoolName }).PoolName
        $mSelTarget = MenuSimple -MenuItems $mOpts -Title $mTitle
        $targetPools = $poolsTb | Where-Object { $_.PoolName -eq $mSelTarget }
    }

    $mTitle = "Continue with update/push of target VDI pool(s) (GI: '$($PoolTempl.ParentVM)', snapshot: '$($PoolTempl.Snapshot)')?"
    $mSchtime = "{0:yyyy-MM-dd HH:mm:ss}" -f $ScheduleTime 
    $mOpts = @("No", "Yes ($($mSchtime))", "Yes (now +$($VAR.UpdateAllDelay)min per each pool)")
    $mSel = MenuSimple -MenuItems $mOpts -Title $mTitle -StartFrom 0
    if($mSel -like "Yes*"){
        $start_time = (Get-Date)
        foreach($target in $targetPools){
            if($target.ParentVMId -eq $PoolTempl.ParentVMId -and $target.SnapshotId -eq $PoolTempl.SnapshotId){
                MsgFce "WARN: Source VDI Pool '$($PoolTempl.PoolName)' and the target VDI Pool '$($target.PoolName)' has the same Parent VM /Golden Image and Snapshot => Skipped" -Output warn
                continue
            }
            MsgFce "ACTION: Scheduling Push Image for pool '$($target.PoolName)'" -Output verbose
            # Schtask StartTime
            if($mSel -match 'now \+(\d+)min'){
                $minutes = $VAR.UpdateAllDelay
                $start_time = ($start_time).AddMinutes($minutes)
            } else{
                $start_time = $ScheduleTime
            }
            $start_time_unix = [DateTimeOffset]::new($start_time.ToUniversalTime()).ToUnixTimeMilliseconds()
            $body = @{
                parent_vm_id = $PoolTempl.ParentVMId
                snapshot_id  = $PoolTempl.SnapshotId
                logoff_policy = $LogoffPolicy
                start_time    = $start_time_unix
                stop_on_first_error = $true
            } | ConvertTo-Json
            # Uri for push image
            $uri = hAPIBuildUri -ApiPath "inventory/v1/desktop-pools/$($target.PoolId)/action/schedule-push-image" -ApiURIbase $API.URIbase
            try{
                $push = Invoke-RestMethod -Method Post -Uri $uri -ContentType "application/json" -Body $body -Headers $API.AuthHeader
                #if($DEBUG){ $push }
                MsgFce ("SUCCESS: Push Image has been scheduled. Start time: {0:yyyy-MM-dd HH:mm:ss}" -f $start_time) -Output success
            } catch{
                MsgFce "ERROR during Push Image process: $($_.Exception.Message)" -Output error
                if($DEBUG -and ($null -ne $_.Exception.Response)){
                    $er = $(New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd()
                    MsgFce "ERR DETAIL: $($er)" -Output error
                }
            }
        }
    } else{
        MsgFce "INFO: Update/push of VDI pool(s) skipped (not selected Yes)" -Output verbose
    }
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