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
        $snapshot = Get-Snapshot -VM $vm -Name $SnapshotName -ErrorAction Stop | Select-Object -First 1

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
        $snapshot = Get-Snapshot -VM $vm -Name $SnapshotName -ErrorAction Stop | Select-Object -First 1

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

# Private helper: returns the first routable IPv4 from a VM view.
# Guest.IpAddress is checked first; if it is IPv6 or empty (VMware Tools can report
# a link-local fe80:: address before DHCP assigns a real IP), we fall back to
# scanning Guest.Net across all NICs for the first IPv4 match.
function Get-BestIPv4 {
    param ($vmView)
    $ipv4Pattern = '^\d{1,3}(\.\d{1,3}){3}$'

    $primary = $vmView.Guest.IpAddress
    if ($primary -match $ipv4Pattern) { return $primary }

    return $vmView.Guest.Net |
        ForEach-Object { $_.IpAddress } |
        Where-Object { $_ -match $ipv4Pattern } |
        Select-Object -First 1
}

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
            Write-Host "[INFO] Waiting for VMware Tools to report an IPv4 address (timeout: ${TimeoutSeconds}s)..." -ForegroundColor Yellow
            $elapsed = 0
            $interval = 5

            while ($elapsed -lt $TimeoutSeconds) {
                $vmView = $vm | Get-View
                $ip = Get-BestIPv4 -vmView $vmView

                if ($ip) {
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
            $ip = Get-BestIPv4 -vmView $vmView

            if (-not $ip) {
                Write-Host "[WARNING] No IPv4 reported for '$($vm.Name)'. VMware Tools may not be running or the VM may still be booting." -ForegroundColor Yellow
                Write-Host "[TIP] Use -WaitForIP to poll until an address is available." -ForegroundColor Cyan
                return $null
            }

            Write-Host "[OK] VM '$($vm.Name)' IP address: $ip" -ForegroundColor Green

            # Also report all IPs across all NICs if there are multiple
            $allIPs = $vmView.Guest.Net |
                ForEach-Object { $_.IpAddress } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
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

# ===== SET VM SPEC FUNCTION =====
# Configures CPU, RAM, and optionally disk size on a VM.
# The VM must be powered off to change hardware specs. If it is running,
# the function will offer to shut it down gracefully before making changes.
# Omit any parameter to leave that spec unchanged.
function Set-VMSpec {
    param (
        [string]$VMName,
        [int]$NumCPU,
        [int]$MemoryGB,
        [int]$DiskGB
    )

    try {
        if (-not $VMName) {
            $vm = Select-VM
            if (-not $vm) { return }
        }
        else {
            $vm = Get-VM -Name $VMName -ErrorAction Stop
        }

        # Hardware changes require the VM to be powered off
        if ($vm.PowerState -eq "PoweredOn") {
            Write-Host "[WARNING] VM '$($vm.Name)' is powered on. It must be shut down to change hardware specs." -ForegroundColor Yellow
            $confirm = Read-Host "Shut down '$($vm.Name)' now? [y/N]"
            if ($confirm -ne 'y' -and $confirm -ne 'Y') {
                Write-Host "[INFO] Cancelled. No changes made." -ForegroundColor Yellow
                return
            }
            Write-Host "[INFO] Shutting down '$($vm.Name)'..." -ForegroundColor Yellow
            Stop-VMGuest -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null

            # Wait for the VM to fully power off
            $timeout = 60
            $elapsed = 0
            while ((Get-VM -Name $vm.Name).PowerState -ne "PoweredOff" -and $elapsed -lt $timeout) {
                Start-Sleep -Seconds 5
                $elapsed += 5
                Write-Host "[INFO] Waiting for shutdown... ($elapsed/${timeout}s)" -ForegroundColor Yellow
            }
            $vm = Get-VM -Name $vm.Name
            if ($vm.PowerState -ne "PoweredOff") {
                Write-Host "[ERROR] VM did not power off within ${timeout}s. Aborting." -ForegroundColor Red
                return
            }
        }

        Write-Host "`n=== Applying Spec Changes to '$($vm.Name)' ===" -ForegroundColor Cyan

        # Build Set-VM parameters dynamically so unspecified values are not touched
        $setVMParams = @{ VM = $vm; ErrorAction = "Stop" }

        if ($NumCPU -gt 0) {
            Write-Host "[INFO] CPU: $($vm.NumCpu) -> $NumCPU" -ForegroundColor Yellow
            $setVMParams["NumCpu"] = $NumCPU
        }

        if ($MemoryGB -gt 0) {
            Write-Host "[INFO] RAM: $($vm.MemoryGB) GB -> $MemoryGB GB" -ForegroundColor Yellow
            $setVMParams["MemoryGB"] = $MemoryGB
        }

        if ($setVMParams.Count -gt 2) {
            Set-VM @setVMParams -Confirm:$false | Out-Null
            Write-Host "[OK] CPU/RAM updated." -ForegroundColor Green
        }

        # Disk resize is handled separately via Set-HardDisk
        if ($DiskGB -gt 0) {
            $disk = Get-HardDisk -VM $vm | Select-Object -First 1
            $currentGB = [math]::Round($disk.CapacityGB)
            if ($DiskGB -le $currentGB) {
                Write-Host "[ERROR] New disk size (${DiskGB} GB) must be larger than current size (${currentGB} GB). Shrinking is not supported." -ForegroundColor Red
            }
            else {
                Write-Host "[INFO] Disk: ${currentGB} GB -> ${DiskGB} GB" -ForegroundColor Yellow
                Set-HardDisk -HardDisk $disk -CapacityGB $DiskGB -Confirm:$false -ErrorAction Stop | Out-Null
                Write-Host "[OK] Disk resized. Remember to extend the partition inside the guest OS after boot." -ForegroundColor Green
            }
        }

        # Show final spec
        $vm = Get-VM -Name $vm.Name
        Write-Host "`n=== Final Spec for '$($vm.Name)' ===" -ForegroundColor Cyan
        Write-Host "  CPU    : $($vm.NumCpu) vCPU(s)"
        Write-Host "  Memory : $($vm.MemoryGB) GB"
        Write-Host "  Disk   : $([math]::Round((Get-HardDisk -VM $vm | Select-Object -First 1).CapacityGB)) GB"

        return $vm
    }
    catch {
        Write-Host "[ERROR] Failed to set VM spec: $_" -ForegroundColor Red
        return $null
    }
}

# ===== SET WINDOWS STATIC IP FUNCTION =====
# Uses Invoke-VMScript (PowerCLI) to run netsh commands inside the guest OS.
# This avoids needing SSH or WinRM — only VMware Tools must be running.
#
# Parameters
#   -VMName        : Name of the target VM in vCenter
#   -InterfaceName : Guest NIC name as seen by Windows (default "Ethernet0")
#   -IPAddress     : Static IPv4 address to assign
#   -SubnetMask    : Subnet mask  (e.g. 255.255.255.0)
#   -Gateway       : Default gateway (e.g. 10.0.5.2)
#   -DNS           : Primary DNS server (e.g. 10.0.5.5)
#   -GuestUser     : Local/domain account inside the guest (e.g. "deployer")
#   -GuestPassword : SecureString — callers should pass (Read-Host -AsSecureString)
#                    The plain-text value is extracted only long enough to be
#                    passed to Invoke-VMScript and is never written to disk.
function Set-WindowsIP {
    param (
        [Parameter(Mandatory)]
        [string]$VMName,

        [string]$InterfaceName = "Ethernet0",

        [Parameter(Mandatory)]
        [string]$IPAddress,

        [string]$SubnetMask = "255.255.255.0",

        [Parameter(Mandatory)]
        [string]$Gateway,

        [Parameter(Mandatory)]
        [string]$DNS,

        [Parameter(Mandatory)]
        [string]$GuestUser,

        [Parameter(Mandatory)]
        [System.Security.SecureString]$GuestPassword
    )

    try {
        # Resolve the VM object
        $vm = Get-VM -Name $VMName -ErrorAction Stop

        if ($vm.PowerState -ne "PoweredOn") {
            Write-Host "[ERROR] VM '$VMName' is not powered on. Start it first." -ForegroundColor Red
            return $null
        }

        # Safely extract the plain-text password from the SecureString
        # only for the duration of this function call.
        $plainPassword = [System.Net.NetworkCredential]::new("", $GuestPassword).Password

        # Build the two netsh commands as a single cmd.exe script block.
        # netsh interface ip set address — sets IP, mask, and gateway in one call.
        # netsh interface ip set dns     — sets the primary DNS server.
        $scriptText = @"
netsh interface ip set address name="$InterfaceName" static $IPAddress $SubnetMask $Gateway
netsh interface ip set dns name="$InterfaceName" static $DNS
"@

        Write-Host "`n=== Setting Static IP on '$VMName' ===" -ForegroundColor Cyan
        Write-Host "  Interface : $InterfaceName"
        Write-Host "  IP        : $IPAddress"
        Write-Host "  Mask      : $SubnetMask"
        Write-Host "  Gateway   : $Gateway"
        Write-Host "  DNS       : $DNS"
        Write-Host "[INFO] Running netsh via Invoke-VMScript..." -ForegroundColor Yellow

        $result = Invoke-VMScript `
            -VM $vm `
            -ScriptText $scriptText `
            -GuestUser $GuestUser `
            -GuestPassword $plainPassword `
            -ScriptType Bat `
            -ErrorAction Stop

        Write-Host "[OK] Static IP configured on '$VMName'." -ForegroundColor Green
        if ($result.ScriptOutput) {
            Write-Host "[OUTPUT] $($result.ScriptOutput)" -ForegroundColor Gray
        }
        return $result
    }
    catch {
        Write-Host "[ERROR] Failed to set Windows IP: $_" -ForegroundColor Red
        return $null
    }
}
