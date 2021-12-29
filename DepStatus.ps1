# Import conf file
foreach ($i in $(Get-Content script.conf)) {
    Set-Variable -Name $i.split("=")[0] -Value $i.split("=", 2)[1]
}

$deployment_ids = @("16784060", "16784055", "16784054", "16784058", "16784057", "16784056", "16784059", "16784063", "16784067", "16784070", "16784069", "16784068", "16784066", "16784065", "16784064", "16784062", "16784061")
$today = get-date

# Dell credentials
$oAuthUri = "https://apigtwb2c.us.dell.com/auth/oauth/v2/token"
$warranty_uri = "https://apigtwb2c.us.dell.com/PROD/sbil/eapi/v5/asset-entitlements"

#  Dell Auth headers
$oAuth = "$client_Id`:$client_secret"

$bytes = [System.Text.Encoding]::ASCII.GetBytes($oAuth)
$encodedOAuth = [Convert]::ToBase64String($bytes)
$headers = @{ }
$headers.Add("authorization", "Basic $encodedOAuth")
$authbody = 'grant_type=client_credentials'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Known windows / sccm update error codes
$error_codes = [PSCustomObject]@{
    "80004004" = "Operation aborted"
    "80004005" = "Unspecified Error"
    "8007000e" = "Windows update encountered an unidentified error"
    "80070057" = "The parameter is incorrect."
    "800705b4" = "This operation returned because the timeout period expired."
    "80240020"	= "Operation did not complete because there is no logged-on interactive user."
    "80240438"	= "There is no route or network connectivity to the endpoint."
    "8024401c"	= "Same as HTTP status 408 � the server timed out waiting for the request."
    "87d00215"	= "Item not found"
    "87d0024a"	= "The job is already connected"
    "87d00324"	= "The application was not detected after installation completed."
    "87d00656"	= "Updates handler was unable to continue due to some generic internal error"
    "87d00664"	= "Updates handler job was cancelled"
    "87d00667"	= "No current or future service window exists to install software updates"
    "87d00692"	= "Group policy conflict"
    "c1900208" = "Incompatible apps or drivers"
    "c190020e"	= "Not enough free disk space"
    "80244010" = "Exceeded max server round trips"
    "80070652" = " ERROR_INSTALL_ALREADY_RUNNING ErrorClientUpdateInProgress"
    "87D00668" = "Software update still detected as actionable after apply"
    "8000FFFF" = "E_UNEXPECTED"
    "C1900107" = "A cleanup operation from a previous installation attempt is still pending and a system reboot is required in order to continue the upgrade."
}

$data = @()

# Login to Dell API
try {
    $oAuthResult = Invoke-RESTMethod -Method Post -Uri $oAuthUri -Body $authbody -Headers $headers
    $token = $oAuthResult.access_token
}
catch {
    $errorMessage = $Error[0]
    Write-Error $errorMessage
    return $null        
}

foreach ($id in $deployment_ids) {
    # Get deployment data
    $instance = Get-CimInstance -ComputerName $SITE_SERVER_NAME -Namespace root\sms\site_$SITE_CODE -class SMS_SUMDeploymentAssetDetails -Filter "AssignmentID = $id AND StatusType != 1" | `
        Select-Object DeviceName, 
    CollectionName,
    @{Name = 'Status' ; Expression = { if ($_.StatusType -eq 2) { 'InProgress' } elseif ($_.StatusType -eq 5) { 'Error' } elseif ($_.StatusType -eq 4) { 'Unknown' } } },
    StatusDescription,
    StatusTime,
    StatusErrorCode 

    # Set headers for dell warranty api req
    $headers = @{"Accept" = "application/json" }
    $headers.Add("Authorization", "Bearer $token")

    $servicetags = $instance.DeviceName | out-string 
    $servicetags = $servicetags -replace ("`r`n", ',')
    $params = @{ }
    $params = @{servicetags = $servicetags; Method = "GET" }


    # Dell warranty API query
    $response = Invoke-RestMethod -Uri $warranty_uri -Headers $headers -Body $params -Method Get -ContentType "application/json"

    foreach ($item in $instance) {
        $x = New-TimeSpan -Start $item.StatusTime -End $today
        $item.StatusTime = "$($x.days) $("days ago")"
        $hex = '{0:x}' -f $item.StatusErrorCode
        $desc = $error_codes.$hex
        $device_name = $item.DeviceName
        $last_online = Get-CimInstance -ComputerName $SITE_SERVER_NAME -Namespace root\sms\site_$SITE_CODE -class SMS_CombinedDeviceResources -Filter "Name = '$($device_name)'" | Select-Object LastActiveTime, LastLogonUser, PrimaryUser
        $last_online = $last_online.LastActiveTime 
        $y = New-TimeSpan -Start $last_online -End $today
        $last_online = "$($y.days) $("days ago")"
        $dell_object = $response | Where-Object -Property servicetag -eq -Value $device_name

        if ($dell_object) {
            $model = $dell_object.productLineDescription 
            $ship_date = $dell_object.shipDate 
            $ship_date = get-date($ship_date)
            $end_date = $ship_date
            $device_type = "Other"
            if ($model -like "*LATITUDE*") {
                $device_type = "Laptop"
                $end_date = $end_date.AddDays(1095)
            }
            elseif ($model -like "*OPTIPLEX*") {
                $device_type = "Desktop"
                $end_date = $end_date.AddDays(1825)
            }

            $out_of_lease = "No"
            if ($today -ge $end_date) {
                $out_of_lease = "Yes"
            }

            $ship_date = $ship_date | get-date -f "dd/MM/yyyy"
            $end_date = $end_date | get-date -f "dd/MM/yyyy"
            $item | Add-Member -MemberType NoteProperty -Name 'Type' -Value $device_type
            $item | Add-Member -MemberType NoteProperty -Name 'Model' -Value $model
            $item | Add-Member -MemberType NoteProperty -Name 'Ship Date' -Value $ship_date 
            $item | Add-Member -MemberType NoteProperty -Name 'Lease End Date' -Value $end_date 
            $item | Add-Member -MemberType NoteProperty -Name 'Lease Ended' -Value $out_of_lease

        }
       
        $item | Add-Member -MemberType NoteProperty -Name 'StatusErrorCodeHex' -Value $hex
        $item | Add-Member -MemberType NoteProperty -Name 'Error Description' -Value $desc
        $item | Add-Member -MemberType NoteProperty -Name 'Device Last Online' -Value $last_online

    }

    $data += $instance
    
}

$data | Sort-Object -Property StatusErrorCode | Export-csv -Path "C:\temp\1809-test.csv" -NoTypeInformation