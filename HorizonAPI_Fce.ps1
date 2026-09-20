<#
.SYNOPSIS
   Horizon REST API Helper Functions Library

.DESCRIPTION
    A collection of useful PowerShell functions designed for working with the Horizon REST API.

.NOTES
   Last Update:    2026-07-09
#>
# ==============================================================================

# Script Messages Function
# Displays a formatted message in the console with color-coding and optionally appends it to the global HTML EmailBody variable.
# Supports message types (info, warn, error, success, etc.), optional blank lines before/after, and stripping of HTML tags for console output.
Function MsgFce{
    param (
        [Parameter(Position=0, Mandatory=$True)] [string] $Msg,
        [ValidateSet("info", "warn", "error", "success", "verbose", "note", "header", "return")] [string] $Output="info",
        [int] $LinesBefore=0,
        [int] $LinesAfter=0,
        [switch] $StripHtml,
        [switch] $NoAddToEmailBody
    )

    $Color = switch($Output){ 
        "warn" {"Yellow"}; "error" {"Red"}; "success" {"Green"}; "verbose" {"Cyan"}; "note" {"DarkGray"}; "header" {"DarkYellow"} 
    }
    # EmailBody helper
    function AddEmailBody([string]$content){
            if(($Script:VAR.EmailBody -is [array]) -and !$NoAddToEmailBody){ $Script:VAR.EmailBody += $content}
    }

    # Padding: Empty Lines Before
    if($LinesBefore){ 1..$LinesBefore | ForEach-Object{ Write-Host ""; AddEmailBody "<br />" } }
    # Msg
    $Msg = if($StripHtml){ $Msg -replace "<[^>]*?>" } else{ $Msg }
    if($Output -eq "return"){ return "`r`n$($Msg)" }

    # Write-Host Msg
    $WriteHostArgs = @{ Object = $Msg }
    if($Color){ $WriteHostArgs.ForegroundColor = $Color }
    if($Output -eq "header"){
        $border = "-" * ($Msg.Length + 4)
        $WriteHostArgs.Object = "$($border)`n  $($Msg.ToUpper())`n$($border)"
        Write-Host @WriteHostArgs
        AddEmailBody "<p><b>$($Msg)</b></p>"
    } else{
        Write-Host @WriteHostArgs
        AddEmailBody $Msg
    }
    # Padding: Empty Lines After
    if($LinesAfter){ 1..$LinesAfter | ForEach-Object { Write-Host ""; AddEmailBody "<br />" } }
}

# Simple choice menu FCE (Writes an output of array items to select)
# Example of use: $MenuItems = @("Yes", "No"); $Title = "Continue?"
function MenuSimple{
    Param(
        [Parameter(Position=0, Mandatory=$True)] [string[]] $MenuItems,
        [string] $Title,
        [boolean] $Cls,
        [int] $StartFrom = 1
    )

    $header = $null
    if(![string]::IsNullOrWhiteSpace($Title)){
        $len = [math]::Max(($MenuItems | Measure-Object -Maximum -Property Length).Maximum, $Title.Length)
        $header = "{0}{1}{2}" -f $Title, [Environment]::NewLine, ("-" * $len)
    }

    # menu items and space align if more than 9 items
    $maxIndex = $StartFrom + $MenuItems.Count - 1
    $len = if($maxIndex -gt 9){ 2 } else{ 1 }
    
    # Counter init and generate menu items
    $currentCounter = $StartFrom
    $items = ($MenuItems | ForEach-Object{ 
        $displayIndex = $currentCounter
        $currentCounter++
        "[{0}]{1}{2}" -f $displayIndex, $(if($displayIndex -lt 10){" " * $len} else{" "}), $_ 
    }) -join [Environment]::NewLine

    # display the menu and return the chosen option
    while($true){
        if($Cls){ Clear-Host } else{ Write-Host }
        if($header){ Write-Host $header -ForegroundColor Yellow }
        Write-Host $items
        Write-Host
        $index = (Read-Host -Prompt 'Please make your choice')
        $index = $index -as [int]
        # Input validation
        if(($StartFrom..$maxIndex) -contains $index){
            return $MenuItems[$index - $StartFrom]
        } else{
            Write-Warning "Invalid choice.. Please try again."
            Start-Sleep -Seconds 2
        }
    }
}

# Horizon API Open Connection & Login
function hAPIConnect{
    param(
        [Parameter(Mandatory=$true)] [string] $ApiURIbase,
        [Parameter(Mandatory=$true)] [string] $username,
        [Parameter(Mandatory=$true)] [System.Security.SecureString] $password,
        [Parameter(Mandatory=$true)] [string] $domain
    )    
    $uri = "$($ApiURIbase)/login"
    $body = @{ username = $username; password = ([System.Net.NetworkCredential]::new("",$password).Password); domain = $domain } | ConvertTo-Json
    try{
        return Invoke-RestMethod -Method Post -Uri $uri -ContentType "application/json" -Body $body
    } catch{
        throw "ERROR: Login to REST API failed: $($_.Exception.Message)"
    }
}

# Horizon API Close Connection & Logout
function hAPIDisconnect{
    param(
        [Parameter(Mandatory=$true)] [string] $ApiURIbase,
        [Parameter(Mandatory=$true)] [object] $ApiToken
    )
    $uri = "$($ApiURIbase)/logout"
    $body = @{ refresh_token = $ApiToken.refresh_token } | ConvertTo-Json
    return Invoke-RestMethod -Method Post -uri $uri -ContentType "application/json" -Body $body -ErrorAction SilentlyContinue
}

# Horizon API Get Auth Header / Access Token
function hAPIGetAuthHeader(){
    param(
        [Parameter(Mandatory=$true)] [object] $ApiToken
    )
    return @{
        "Authorization" = "Bearer $($ApiToken.access_token)"
        "Content-Type" = "application/json"
    }
}

# Horizon API Build Uri(Query) fce (with filtering)
function hAPIBuildUri{
    param(
        [Parameter(Mandatory=$true)] [string] $ApiPath,
        [Parameter(Mandatory=$true)] [string] $ApiURIbase,
        [Parameter(Mandatory=$false)] [hashtable] $QueryData = @{},
        [Parameter(Mandatory=$false)] [string] $FilterName,
        [Parameter(Mandatory=$false)] [string] $FilterValue
    )
    $uri = "$($ApiURIbase.TrimEnd('/'))/$($ApiPath.TrimStart('/'))"
    $queryParams = New-Object System.Collections.Generic.List[string]

    if(-not [string]::IsNullOrEmpty($FilterName) -and -not [string]::IsNullOrEmpty($FilterValue)){
        $filter = [ordered]@{ 
            "type" = "And"
            "filters" = @(@{ "type"="Equals"; "name"=$FilterName; "value"=$FilterValue }) 
        }
        $jsonFilter = $filter | ConvertTo-Json -Compress
        $queryParams.Add("filter=" + [Uri]::EscapeDataString($jsonFilter))
    }
    # Other query parameters
    foreach($key in $QueryData.Keys){ 
        $queryParams.Add("$key=$($QueryData[$key])")
    }
    if($queryParams.Count -gt 0){
        $uri += "?" + ($queryParams -join "&")
    }
    return $uri
}

# Horizon API universal fce for getting object(s)
function hAPIGetObject{
    param(
        [Parameter(Mandatory=$true)] [string] $ApiPath,
        [Parameter(Mandatory=$true)] [hashtable] $ApiAuthHeader,
        [Parameter(Mandatory=$true)] [string] $ApiURIbase,   
        [Parameter(Mandatory=$false)] [string] $FilterValue,
        [Parameter(Mandatory=$false)] [string] $FilterName = "name",
        [Parameter(Mandatory=$false)] [hashtable] $AdditionalParams = @{}
    )
    $uri = hAPIBuildUri -ApiPath $ApiPath -ApiURIbase $ApiURIbase -FilterName $FilterName -FilterValue $FilterValue -QueryData $AdditionalParams
    try{
        $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $ApiAuthHeader -ContentType "application/json"
        if($null -eq $response) { return @() }
        if($response.PSObject.Properties['value']) { return @($response.value) }
        return @($response)
    } catch {
        if($DEBUG){ MsgFce "DEBUG: API Request failed at $($ApiPath)" -Output verbose }
        return @()
    }
}

# Horizon API fce for getting desktop pool(s)
function hAPIGetDesktopPool{
    param(
        [Parameter(Mandatory=$true)] [string] $ApiURIbase,
        [Parameter(Mandatory=$true)] [hashtable] $ApiAuthHeader,
        [Parameter(Mandatory=$false)] [string] $FilterValue
    )
    $apidata = hAPIGetObject -ApiPath "inventory/v2/desktop-pools" -FilterValue $FilterValue -ApiUriBase $ApiURIbase -ApiAuthHeader $ApiAuthHeader
    if(-not [string]::IsNullOrEmpty($FilterValue)){
        if($apidata.Count -eq 0){ return $null }
        return $apidata[0] 
    }
    return $apidata
}

# Get Specific Desktop Pool Details
function hAPIGetDesktopPoolDetail{
    param(
        [Parameter(Mandatory=$true)] [string] $ApiURIbase,
        [Parameter(Mandatory=$true)] [hashtable] $ApiAuthHeader,
        [Parameter(Mandatory=$true)] [string] $Id
    )
    # We call hAPIGetObject without a FilterValue to get the specific ID resource
    $apidata = hAPIGetObject -ApiPath "inventory/v11/desktop-pools/$($Id)" -ApiUriBase $ApiURIbase -ApiAuthHeader $ApiAuthHeader
    if(@($apidata).Count -gt 0) {
        return $apidata[0]
    }
    return $null
}

# Horizon API fce for getting vCenter Server
function hAPIGetVCenter{
    param(
        [Parameter(Mandatory=$true)] [string] $ApiURIbase,
        [Parameter(Mandatory=$true)] [hashtable] $ApiAuthHeader,
        [Parameter(Mandatory=$false)] [string] $FilterValue,
        [Parameter(Mandatory=$false)] [string] $FilterName = "server_name"
    )
    $apidata = hAPIGetObject -ApiPath "config/v2/virtual-centers" -ApiUriBase $ApiURIbase -ApiAuthHeader $ApiAuthHeader
    if(-not [string]::IsNullOrEmpty($FilterValue)){
        # Manual filtering as vCenter API often uses server_name instead of name for filters
        $res = $apidata | Where-Object { $_.$FilterName -eq $FilterValue }
        if(@($res).Count -eq 0){ return $null }
        return @($res)[0]
    }
    return $apidata
}

# Horizon API fce for getting Base/Parent VM
function hAPIGetBaseVm{
    param(
        [Parameter(Mandatory=$true)] [string] $ApiURIbase,
        [Parameter(Mandatory=$true)] [hashtable] $ApiAuthHeader,
        [Parameter(Mandatory=$false)] [string] $FilterValue,
        [Parameter(Mandatory=$true)] [string] $vCenterId
    )
    $apidata = hAPIGetObject -ApiPath "external/v2/base-vms" -FilterValue $FilterValue -AdditionalParams @{vcenter_id = $vCenterId} -ApiUriBase $ApiURIbase -ApiAuthHeader $ApiAuthHeader
    if(-not [string]::IsNullOrEmpty($FilterValue)){
        if($apidata.Count -eq 0){ return $null }
        return $apidata[0]
    }
    return $apidata
}

# Resolve Base VM ID to Object
function hAPIGetBaseVmById{
    param(
        [Parameter(Mandatory=$true)] [string] $ApiURIbase,
        [Parameter(Mandatory=$true)] [hashtable] $ApiAuthHeader,
        [Parameter(Mandatory=$true)] [string] $Id,
        [Parameter(Mandatory=$true)] [string] $vCenterId
    )
    $apidata = hAPIGetObject -ApiPath "external/v2/base-vms" -FilterValue $Id -FilterName "id" -AdditionalParams @{vcenter_id = $vCenterId} -ApiUriBase $ApiURIbase -ApiAuthHeader $ApiAuthHeader
    if($apidata.Count -eq 0){ return $null }
    return $apidata[0]
}

# Horizon API fce for getting Base/Parent VM Snapshot(s)
function hAPIGetBaseVmSnapshot{
    param(
        [Parameter(Mandatory=$true)] [string] $ApiURIbase,
        [Parameter(Mandatory=$true)] [hashtable] $ApiAuthHeader,
        [Parameter(Mandatory=$false)] [string] $FilterValue,
        [Parameter(Mandatory=$true)] [string] $vCenterId,
        [Parameter(Mandatory=$true)] [string] $BaseVmId
    )
    $apidata = hAPIGetObject -ApiPath "external/v2/base-snapshots" -FilterValue $FilterValue -AdditionalParams @{vcenter_id = $vCenterId; base_vm_id = $BaseVmId} -ApiUriBase $ApiURIbase -ApiAuthHeader $ApiAuthHeader
    if(-not [string]::IsNullOrEmpty($FilterValue)){
        if($apidata.Count -eq 0){ return $null }
        return $apidata[0]
    }
    return $apidata
}

# Resolve Snapshot ID to Object
function hAPIGetBaseVmSnapshotById{
    param(
        [Parameter(Mandatory=$true)] [string] $ApiURIbase,
        [Parameter(Mandatory=$true)] [hashtable] $ApiAuthHeader,
        [Parameter(Mandatory=$true)] [string] $Id,
        [Parameter(Mandatory=$true)] [string] $vCenterId,
        [Parameter(Mandatory=$true)] [string] $BaseVmId
    )
    $apidata = hAPIGetObject -ApiPath "external/v2/base-snapshots" -FilterValue $Id -FilterName "id" -AdditionalParams @{vcenter_id = $vCenterId; base_vm_id = $BaseVmId} -ApiUriBase $ApiURIbase -ApiAuthHeader $ApiAuthHeader
    if($apidata.Count -eq 0){ return $null }
    return $apidata[0]
}
