VMstate.ps1 is used to either startup or shutdown an azure vm based upon a resource tag. The script will also update a ServiceNow table so that the monitoring for the VM is 
disabled while in a shutdown state.

Get-VMlastpatch will query a Log analytics workspace and return the date that all VMs were lasted patch with a security update in a CSV file
