VMstate.ps1 is used to either startup or shutdown an azure vm based upon a resource tag. The script will also update a ServiceNow table so that the monitoring for the VM is 
disabled while in a shutdown state.

Get-VMlastpatch will query a Log analytics workspace and return the date that all VMs were lasted patched with a security update in a CSV file.

Tag-vmresources appends azure tags based on either the tags present on the vm or the resource group that it resides in
