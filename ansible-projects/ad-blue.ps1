# ============================================================
#  480Driver.ps1  –  Lab: dc-blue1 deployment & static IP
# ============================================================
# Load the utility module (adjust path if yours differs)
Import-Module "/home/connor/480-DevOps/480Utils.psm1" -Force

# ── 1. Connect to vCenter ───────────────────────────────────
Connect-480VIServer

# ── 2. Create the linked clone from win-srv-2019 base ───────
#  Places dc-blue1 on the BLUE-LAN port group.
#  New-LinkedClone uses 480.json for ESXi host, datastore, and
#  snapshot name, so only the VM/clone names need to be supplied.
$dcBlue1 = New-LinkedClone `
    -VMName   "server.2019.base.v2" `
    -CloneName "dc-blue1"

if (-not $dcBlue1) {
    Write-Host "[FATAL] Linked clone creation failed. Aborting." -ForegroundColor Red
    exit 1
}

# Move the NIC to BLUE-LAN immediately after cloning
Connect-480VIServer
Set-VMNetwork -VMName "dc-blue1" -NetworkName "blue"

# ── 3. Start dc-blue1 ───────────────────────────────────────
Invoke-StartVM -VMName "dc-blue1"
# Give VMware Tools time to fully initialise before we send
# guest scripts.  Adjust the timeout if your template boots slowly.
Write-Host "[INFO] Waiting for VMware Tools to come online..." -ForegroundColor Yellow
Get-VMIPAddress -VMName "dc-blue1" -WaitForIP -TimeoutSeconds 180

# ── 4. Collect guest credentials securely ───────────────────
#  Read-Host -AsSecureString never stores the password as plain text.
Write-Host "`nEnter the guest credentials for dc-blue1" -ForegroundColor Cyan
$guestUser = Read-Host "Guest username (e.g. deployer)"
$securePass = Read-Host "Guest password" -AsSecureString

# ── 5. Set the static IP inside dc-blue1 ────────────────────
#  10.0.5.0/24 network:
#    Host IP  : 10.0.5.5
#    Mask     : 255.255.255.0
#    Gateway  : 10.0.5.2  (VyOS BLUE-LAN interface)
#    DNS      : 10.0.5.5  (this DC will serve its own zone;
#                          change to 10.0.5.2 or 8.8.8.8 until
#                          AD DNS is configured if preferred)
Set-WindowsIP `
    -VMName        "dc-blue1" `
    -InterfaceName "Ethernet0" `
    -IPAddress     "10.0.5.6" `
    -SubnetMask    "255.255.255.0" `
    -Gateway       "10.0.5.2" `
    -GuestUser     $guestUser `
    -GuestPassword $securePass

Write-Host "`n[DONE] dc-blue1 is up and has a static IP of 10.0.5.5" -ForegroundColor Green