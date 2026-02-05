$vserver="vcenter.east.local"
Connect-VIServer($vserver)
#Source VM
$vm=Get-VM -Name vyos
$snapshot = Get-Snapshot -VM $vm -Name "base"
$vmhost = Get-VMHost -Name "192.168.3.206"
$ds=Get-DataStore -Name datastore2
$linkedname = "{0}.linked" -f $vm.name
#Create the tempory VM
$linkedvm = New-VM -LinkedClone -Name $linkedName -VM $vm -ReferenceSnapshot $snapshot -VMHost $vmhost -Datastore $ds
#Create the Full VM
$newvm = New-VM -Name "GW-FW-01" -VM $linkedvm -VMHost $vmhost -Datastore $ds
#A new Snap Shot
$newvm | new-snapshot -Name "base"
#Cleanup the temporary linked clone
$linkedvm | Remove-VM
