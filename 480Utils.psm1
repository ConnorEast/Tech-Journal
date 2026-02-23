# 480Utils.psm1 - PowerShell Module for VM Cloning Operations

# ===== CONFIGURATION FUNCTION =====
# this section of the script collects the information from the 480.json file and returns it as a PowerShell object. this is useful as it means it is accessible to all other functions within this "module skeleton"
function Get-480Config {
    param (
        [string]$ConfigPath = "/home/connor/480-DevOps/480.json"
    )

    try {
        #if the file 480.json does not exist at the specified location throw a configuration error in red.
        if (-not (Test-Path $ConfigPath)) {
            Write-Host "[ERROR] Config file not found: $ConfigPath" -ForegroundColor Red
            return $null
        }
       # this collects the data in the config file and converts it from json to a powershell object, then returns it to be used by other functions. before writing "configuration loaded"
        $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
        Write-Host "[OK] Configuration loaded" -ForegroundColor Green
        return $config
    }
    catch {
        # if the actual file could not be loaded for whatever reason. A Error message is printed and the function ends.
        Write-Host "[ERROR] Failed to load config: $_" -ForegroundColor Red
        return $null
    }
}
# ===== VCENTER CONNECTION FUNCTION =====
# This one is simple. It runs the config function to get the needed data before parsing it to a connection function. This function allows us to log in to vcenter and is required for the functionality of all active deployments. It also checks if we are already connected to avoid unnecessary reconnections, and it ignores certificate warnings for smoother operation.
function Connect-480VIServer {
    $config = Get-480Config
    if (-not $config) { return }

    try {
        # Check if already connected
        $existingConnection = $global:DefaultVIServer
        if ($existingConnection -and $existingConnection.IsConnected) {
            Write-Host "[OK] Already connected to $($existingConnection.Name)" -ForegroundColor Green
            return $existingConnection
        }

        # Ignore certificate warnings
        Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null

        # Connect to vCenter
        Write-Host "[INFO] Connecting to $($config.serverEast)..." -ForegroundColor Yellow
        $connection = Connect-VIServer -Server $config.serverEast

        Write-Host "[OK] Connected to $($config.serverEast)" -ForegroundColor Green
        return $connection
    }
    catch {
        # if the connection fails for whatever reason, an error message is printed and the function ends.
        Write-Host "[ERROR] Failed to connect to vCenter: $_" -ForegroundColor Red
        return $null
    }
}


# ===== VM SELECTION FUNCTION =====
# this section parses all VM's on the server. You can then choose what vms you would want to clone. in future implementations I may try and make it pull only from the "Base-Vms's folder, but for now it just pulls all of them. It also checks if there are no vms found and prints a warning if that is the case. The function then lists all the vms with a number next to them and prompts the user to enter the number of the vm they want to select. If the selection is valid, it returns the selected vm object. If the selection is invalid, it prints an error message and returns null."
function Select-VM {
    param (
        [string]$FolderName
    )

    try {
        if ($FolderName) {
            $vms = Get-VM -Location $FolderName | Sort-Object Name
        }
        else {
            $vms = Get-VM | Sort-Object Name
        }

        if ($vms.Count -eq 0) {
            Write-Host "[WARNING] No VMs found" -ForegroundColor Yellow
            return $null
        }

        Write-Host "`n=== Select a VM ===" -ForegroundColor Cyan
        for ($i = 0; $i -lt $vms.Count; $i++) {
            Write-Host "[$i] $($vms[$i].Name)"
        }

        $selection = Read-Host "`nEnter VM number"
       
        if ($selection -match '^\d+$' -and [int]$selection -ge 0 -and [int]$selection -lt $vms.Count) {
            $selectedVM = $vms[[int]$selection]
            Write-Host "[OK] Selected: $($selectedVM.Name)" -ForegroundColor Green
            return $selectedVM
        }
        else {
            Write-Host "[ERROR] Invalid selection" -ForegroundColor Red
            return $null
        }
    }
    catch {
        Write-Host "[ERROR] Failed to select VM: $_" -ForegroundColor Red
        return $null
    }
}


# ===== LINKED CLONE FUNCTION =====
function New-LinkedClone {
    param (
        [string]$VMName,
        [string]$CloneName,
        [string]$ESXiHost,
        [string]$Datastore,
        [string]$SnapshotName
    )

    $config = Get-480Config
    if (-not $config) { return }

    try {
        if (-not $VMName) {
            $vm = Select-VM
            if (-not $vm) { return }
        }
        else {
            $vm = Get-VM -Name $VMName -ErrorAction Stop
        }

        if (-not $CloneName) {
            $CloneName = Read-Host "Enter name for the linked clone"
            if ([string]::IsNullOrWhiteSpace($CloneName)) {
                Write-Host "[ERROR] Clone name cannot be empty" -ForegroundColor Red
                return
            }
        }

        $existingVM = Get-VM -Name $CloneName -ErrorAction SilentlyContinue
        if ($existingVM) {
            Write-Host "[ERROR] VM '$CloneName' already exists" -ForegroundColor Red
            return
        }

        if (-not $ESXiHost) {
            $ESXiHost = Read-Host "Enter ESXi host [$($config.esxiEast)]"
            if ([string]::IsNullOrWhiteSpace($ESXiHost)) {
                $ESXiHost = $config.esxiEast
            }
        }
        $vmhost = Get-VMHost -Name $ESXiHost -ErrorAction Stop

        if (-not $Datastore) {
            $Datastore = Read-Host "Enter datastore [$($config.datastore)]"
            if ([string]::IsNullOrWhiteSpace($Datastore)) {
                $Datastore = $config.datastore
            }
        }
        $ds = Get-Datastore -Name $Datastore -ErrorAction Stop

        if (-not $SnapshotName) {
            $SnapshotName = $config.base_snapshot
        }
        $snapshot = Get-Snapshot -VM $vm -Name $SnapshotName -ErrorAction Stop

        Write-Host "`n=== Creating Linked Clone ===" -ForegroundColor Cyan
        Write-Host "Source VM: $($vm.Name)"
        Write-Host "Snapshot: $SnapshotName"
        Write-Host "Clone Name: $CloneName"
        Write-Host "ESXi Host: $ESXiHost"
        Write-Host "Datastore: $Datastore"

        $linkedClone = New-VM -LinkedClone -Name $CloneName -VM $vm -ReferenceSnapshot $snapshot -VMHost $vmhost -Datastore $ds -ErrorAction Stop

        Write-Host "[OK] Linked clone '$CloneName' created!" -ForegroundColor Green
        return $linkedClone
    }
    catch {
        Write-Host "[ERROR] Failed to create linked clone: $_" -ForegroundColor Red
        return $null
    }
}


# ===== FULL CLONE FUNCTION =====
function New-FullClone {
    param (
        [string]$VMName,
        [string]$CloneName,
        [string]$ESXiHost,
        [string]$Datastore,
        [string]$SnapshotName
    )

    $config = Get-480Config
    if (-not $config) { return }

    try {
        if (-not $VMName) {
            $vm = Select-VM
            if (-not $vm) { return }
        }
        else {
            $vm = Get-VM -Name $VMName -ErrorAction Stop
        }

        if (-not $CloneName) {
            $CloneName = Read-Host "Enter name for the full clone"
            if ([string]::IsNullOrWhiteSpace($CloneName)) {
                Write-Host "[ERROR] Clone name cannot be empty" -ForegroundColor Red
                return
            }
        }

        $existingVM = Get-VM -Name $CloneName -ErrorAction SilentlyContinue
        if ($existingVM) {
            Write-Host "[ERROR] VM '$CloneName' already exists" -ForegroundColor Red
            return
        }

        if (-not $ESXiHost) {
            $ESXiHost = Read-Host "Enter ESXi host [$($config.esxiEast)]"
            if ([string]::IsNullOrWhiteSpace($ESXiHost)) {
                $ESXiHost = $config.esxiEast
            }
        }
        $vmhost = Get-VMHost -Name $ESXiHost -ErrorAction Stop

        if (-not $Datastore) {
            $Datastore = Read-Host "Enter datastore [$($config.datastore)]"
            if ([string]::IsNullOrWhiteSpace($Datastore)) {
                $Datastore = $config.datastore
            }
        }
        $ds = Get-Datastore -Name $Datastore -ErrorAction Stop

        if (-not $SnapshotName) {
            $SnapshotName = $config.base_snapshot
        }
        $snapshot = Get-Snapshot -VM $vm -Name $SnapshotName -ErrorAction Stop

        Write-Host "`n=== Creating Full Clone ===" -ForegroundColor Cyan
        Write-Host "Source VM: $($vm.Name)"
        Write-Host "Snapshot: $SnapshotName"
        Write-Host "Clone Name: $CloneName"
        Write-Host "ESXi Host: $ESXiHost"
        Write-Host "Datastore: $Datastore"

        $linkedName = "{0}.linked" -f $vm.Name
        Write-Host "`n[INFO] Creating temporary linked clone..." -ForegroundColor Yellow
        $linkedvm = New-VM -LinkedClone -Name $linkedName -VM $vm -ReferenceSnapshot $snapshot -VMHost $vmhost -Datastore $ds -ErrorAction Stop

        Write-Host "[INFO] Creating full clone (this may take a while)..." -ForegroundColor Yellow
        $newvm = New-VM -Name $CloneName -VM $linkedvm -VMHost $vmhost -Datastore $ds -ErrorAction Stop

        Write-Host "[INFO] Creating base snapshot..." -ForegroundColor Yellow
        $newvm | New-Snapshot -Name "Base" -ErrorAction Stop

        Write-Host "[INFO] Cleaning up temporary clone..." -ForegroundColor Yellow
        $linkedvm | Remove-VM -Confirm:$false -ErrorAction Stop

        Write-Host "[OK] Full clone '$CloneName' created!" -ForegroundColor Green
        return $newvm
    }
    catch {
        Write-Host "[ERROR] Failed to create full clone: $_" -ForegroundColor Red
       
        $tempClone = Get-VM -Name "*.linked" -ErrorAction SilentlyContinue
        if ($tempClone) {
            Write-Host "[INFO] Cleaning up temporary clone..." -ForegroundColor Yellow
            $tempClone | Remove-VM -DeletePermanently -Confirm:$false -ErrorAction SilentlyContinue
        }
        return $null
    }
}