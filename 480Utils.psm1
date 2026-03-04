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

# ===== VM Start Script =====
function Invoke-StartVM {
    param (
        [string]$VMName
    )
    try {
        if (-not $VMName) {
            $vm = Select-VM
            if (-not $vm) { return }
        }
        else {
            $vm = Get-VM -Name $VMName -ErrorAction Stop
        }
        if ($vm.PowerState -eq "PoweredOn") {
            Write-Host "[WARNING] VM '$($vm.Name)' is already powered on" -ForegroundColor Yellow
            return $vm
        }

        Write-Host "[INFO] Starting VM '$($vm.Name)'..." -ForegroundColor Yellow
        Start-VM -VM $vm -ErrorAction Stop | Out-Null
        Write-Host "[OK] VM '$($vm.Name)' started!" -ForegroundColor Green
        return $vm
    }
    catch {
        Write-Host "[ERROR] Failed to start VM: $_" -ForegroundColor Red
        return $null
    }
}

# ===== Turn off VM =====
# FIX: Changed Shutdown-VMGuest to Stop-VMGuest. Shutdown-VMGuest is not a valid PowerCLI cmdlet.
# Stop-VMGuest sends a graceful shutdown signal via VMware Tools (same behaviour, correct cmdlet).
function Invoke-ShutdownVM {
    param (
        [string]$VMName
    )
    try {
        if (-not $VMName) {
            $vm = Select-VM
            if (-not $vm) { return }
        }
        else {
            $vm = Get-VM -Name $VMName -ErrorAction Stop
        }
        if ($vm.PowerState -eq "PoweredOff") {
            Write-Host "[WARNING] VM '$($vm.Name)' is already powered off" -ForegroundColor Yellow
            return $vm
        }

        Write-Host "[INFO] Shutting down VM '$($vm.Name)'..." -ForegroundColor Yellow
        Stop-VMGuest -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null
        Write-Host "[OK] VM '$($vm.Name)' shutdown initiated!" -ForegroundColor Green
        return $vm
    }
    catch {
        Write-Host "[ERROR] Failed to shut down VM: $_" -ForegroundColor Red
        return $null
    }
}


# ===== Network Creation Script =====
# FIX: Added existence check for port group before creating it, matching the existing vSwitch check.
# Without this, re-running the function would throw a duplicate port group error.
function Create-Network {
    param (
        [string]$SwitchName,
        [string]$PortGroupName,
        [string]$ESXiHost
    )

    $config = Get-480Config
    if (-not $config) { return }

    try {
        if (-not $ESXiHost) { $ESXiHost = $config.esxiEast }
        $vmhost = Get-VMHost -Name $ESXiHost -ErrorAction Stop

        if (-not $SwitchName) { $SwitchName = Read-Host "Please enter the name of the vSwitch to create" }

        if (-not $PortGroupName) { $PortGroupName = Read-Host "Please enter the name of the port group to create" }
       
        $existingSwitch = Get-VirtualSwitch -VMHost $vmhost -Name $SwitchName -ErrorAction SilentlyContinue
        if (-not $existingSwitch) {
            Write-Host "[INFO] Deploying vSwitch $SwitchName..." -ForegroundColor Yellow
            $vswitch = New-VirtualSwitch -VMHost $vmhost -Name $SwitchName -ErrorAction Stop
            Write-Host "[OK] vSwitch '$SwitchName' created!" -ForegroundColor Green
        }
        else {
            Write-Host "[OK] vSwitch '$SwitchName' already exists" -ForegroundColor Yellow
            $vswitch = $existingSwitch
        }

        $existingPortGroup = Get-VirtualPortGroup -VirtualSwitch $vswitch -Name $PortGroupName -ErrorAction SilentlyContinue
        if (-not $existingPortGroup) {
            Write-Host "[INFO] Deploying port group $PortGroupName..." -ForegroundColor Yellow
            $portgroup = New-VirtualPortGroup -VirtualSwitch $vswitch -Name $PortGroupName -ErrorAction Stop
            Write-Host "[OK] Port group '$PortGroupName' created!" -ForegroundColor Green
        }
        else {
            Write-Host "[OK] Port group '$PortGroupName' already exists" -ForegroundColor Yellow
            $portgroup = $existingPortGroup
        }

        return $portgroup
    }
    catch {
        Write-Host "[ERROR] Failed to create network: $_" -ForegroundColor Red
        return $null
    }
}

# ===== Setting VM Network Function =====
# FIX: Corrected "[error]" tag to "[ERROR]" for consistency with the rest of the module.
function Set-VMNetwork {
    param (
        [string]$VMName,
        [string]$NetworkName,
        [int]$AdapterIndex = 0
    )
    try {
        if (-not $VMName) {
            $vm = Select-VM
            if (-not $vm) { return }
        }
        else {
            $vm = Get-VM -Name $VMName -ErrorAction Stop
        }
        if (-not $NetworkName) {
            $NetworkName = Read-Host "Enter network name to connect VM to"
            if ([string]::IsNullOrWhiteSpace($NetworkName)) {
                Write-Host "[ERROR] Network name cannot be empty" -ForegroundColor Red
                return
            }
        }
        $adapters = @(Get-NetworkAdapter -VM $vm)
        if ($adapters.Count -eq 0) {
            Write-Host "[ERROR] No network adapters found on VM '$($vm.Name)'" -ForegroundColor Red
            return
        }
        Write-Host "=== Listing Network Adapters for VM '$($vm.Name)' ===" -ForegroundColor Cyan
        for ($i = 0; $i -lt $adapters.Count; $i++) {
            Write-Host "[$i] $(($adapters[$i]).Name) - Current Network: $(($adapters[$i]).NetworkName)"
        }
        $targetAdapter = $adapters[$AdapterIndex]
        Write-Host "[INFO] Setting adapter [$AdapterIndex] '$($targetAdapter.Name)' to network '$NetworkName'..." -ForegroundColor Yellow
        Set-NetworkAdapter -NetworkAdapter $targetAdapter -NetworkName $NetworkName -Confirm:$false -ErrorAction Stop | Out-Null
        Write-Host "[OK] Adapter has been set to network '$NetworkName'!" -ForegroundColor Green
    }
    catch {
        Write-Host "[ERROR] Failed to set VM network: $_" -ForegroundColor Red
        return $null
    }
}

# ===== FULL CLONE FUNCTION =====
# FIX: Added -DeletePermanently to the happy-path linked clone removal so disk files are also cleaned up,
# matching the catch block behaviour. Without this the temp linked clone's vmdk files were left on the datastore.
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
        $linkedvm | Remove-VM -DeletePermanently -Confirm:$false -ErrorAction Stop

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

# ===== GET VM IP ADDRESS FUNCTION =====
# Retrieves the IP address(es) of a VM via VMware Tools guest info.
# The VM must be powered on and have VMware Tools running for this to work.
# An optional -WaitForIP switch will poll until an IP is reported, useful immediately after boot.
function Get-VMIPAddress {
    param (
        [string]$VMName,
        [switch]$WaitForIP,
        [int]$TimeoutSeconds = 120
    )

    try {
        if (-not $VMName) {
            $vm = Select-VM
            if (-not $vm) { return }
        }
        else {
            $vm = Get-VM -Name $VMName -ErrorAction Stop
        }

        if ($vm.PowerState -ne "PoweredOn") {
            Write-Host "[ERROR] VM '$($vm.Name)' is not powered on. Start the VM first." -ForegroundColor Red
            return $null
        }

        if ($WaitForIP) {
            Write-Host "[INFO] Waiting for VMware Tools to report an IP (timeout: ${TimeoutSeconds}s)..." -ForegroundColor Yellow
            $elapsed = 0
            $interval = 5

            while ($elapsed -lt $TimeoutSeconds) {
                $vmView = $vm | Get-View
                $ip = $vmView.Guest.IpAddress

                if (-not [string]::IsNullOrWhiteSpace($ip)) {
                    Write-Host "[OK] VM '$($vm.Name)' IP address: $ip" -ForegroundColor Green
                    return $ip
                }

                Start-Sleep -Seconds $interval
                $elapsed += $interval
                $vm = Get-VM -Name $vm.Name  # refresh the VM object
                Write-Host "[INFO] Still waiting... ($elapsed/${TimeoutSeconds}s)" -ForegroundColor Yellow
            }

            Write-Host "[ERROR] Timed out waiting for IP address on VM '$($vm.Name)'" -ForegroundColor Red
            return $null
        }
        else {
            # Immediate check via the VM's guest info view
            $vmView = $vm | Get-View
            $ip = $vmView.Guest.IpAddress

            if ([string]::IsNullOrWhiteSpace($ip)) {
                Write-Host "[WARNING] No IP reported for '$($vm.Name)'. VMware Tools may not be running or the VM may still be booting." -ForegroundColor Yellow
                Write-Host "[TIP] Use -WaitForIP to poll until an address is available." -ForegroundColor Cyan
                return $null
            }

            Write-Host "[OK] VM '$($vm.Name)' IP address: $ip" -ForegroundColor Green

            # Also report all IPs across all NICs if there are multiple
            $allIPs = $vmView.Guest.Net | ForEach-Object { $_.IpAddress } | Where-Object { $_ -ne $null }
            if ($allIPs.Count -gt 1) {
                Write-Host "[INFO] All reported addresses:" -ForegroundColor Cyan
                $allIPs | ForEach-Object { Write-Host "  - $_" }
            }

            return $ip
        }
    }
    catch {
        Write-Host "[ERROR] Failed to get IP address: $_" -ForegroundColor Red
        return $null
    }
}
