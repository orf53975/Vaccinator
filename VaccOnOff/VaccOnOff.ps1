##########################################################################################################
#                                                                                                        #
#                                             The VaccOnOff                                              #
#                                                                                                        #
#                                                                                                        #
# This script is supposed to detect malware that attempts to hide from forensic tools.                   #
# This kind of malwares ends/suspends their process when they detect a forensics-related process running #
# Evasive malware can look for other indicators than ptocesses (i.e. registry keys),                     #
# This will be covered in the next version.                                                              #
# A list of process names is available at: https://github.com/DuckInCyber/Vaccinator                     #
#                                                                                                        #
# You can use the simple exe I uploaded or any exe you want.                                             #
# Change the name of the exe to the names on the list (or use your own names).                           #
# Pull all the exe files you want in a folder                                                            #
#                                                                                                        #
# Written by DuckInCyber                                                                                 #
# Date 31/7/18                                                                                           #
# Version 0.0.1                                                                                          #
#                                                                                                        #
##########################################################################################################

####################### Stuff you need to change ###########################
## Variables

## Result output path
## You need a network path with full control permissions for Everyone or Domain Computers
$path = "\\net_share\folder_with_everyone_FullControl_permission\output"

## You better change it to something else
$file_path = "c:\stopped.csv"

## folder of processes
## you can put this folder in a share (With only read permissions to EVERYONE) or you can copy it from the server when you distribute the script
## If you are not using the network path, uncomment the first section and comment the second one

#$proc_files_dir = "c:\tools" ## Make sure the path doesn't end with a '\'
#$proc_files = Get-ChildItem $proc_files_dir | select -ExpandProperty FullName

$local_path = "c:\tools"
$proc_files_dir = "\\net_share\folder_with_everyone_read_permission\tools" ## Make sure the path doesn't end with a '\'
Copy-Item $proc_files_dir -Destination $local_path -Force -Recurse
$proc_files = Get-ChildItem $local_path | select -ExpandProperty FullName

## sleep between Process launch in miliseconds
$sleep = 2000

## Domain and user/group  which have permissions to read and write to the output file
$domain = "domain"
$user = "user"

############################################################################################

## Get the processes which are in a "suspended" state
function get-suspended ()
{

# get process
$processes = Get-Process *
$list = @()
foreach ($process in $processes) 
{

  # Check each thread
  foreach ($thread in $process.Threads) 
  {   
    if($thread.ThreadState -eq "Wait") 
    {
        $temp = $process | select -prop Name, Id, Path
        $temp | Add-Member -Type NoteProperty -Value  $thread.WaitReason.ToString() -Name "status"
        $list += $temp
    }
  }
}

# remove duplicates
$list = $list | ?{$_.status -like "*Suspended*"} | select -Uniq Name, Id, Path
return $list
}




##### start main #####

## Getting the suspended process so I will be able to find the new suspended processes.
$suspend_at_start = get-suspended
$suspend_at_start_info = $processes = Get-WmiObject win32_process # wmi - because I want the commandline


## Listenning to closing processes
# Collect processes that terminated
# I am using wmi subscription 
# Explanation  - https://learn-powershell.net/2013/08/14/powershell-and-events-permanent-wmi-event-subscriptions/amp/
#
#### Credit to Amit Avni on the WNI part ####
#
# parameter - file path

$instanceFilter = ([wmiclass]"\\.\root\subscription:__EventFilter").CreateInstance()
$instanceFilter.QueryLanguage = "WQL"
$instanceFilter.Query = "select * from __InstanceDeletionEvent within 2 where targetInstance isa 'win32_Process'"
$instanceFilter.Name = "ProcessFilter"
$instanceFilter.EventNamespace = 'root\cimv2'
$instancefilter | Get-Member -View All
$result = $instanceFilter.Put()
$newFilter = $result.Path

#Creating a new event consumer
$instanceConsumer = ([wmiclass]"\\.\root\subscription:LogFileEventConsumer").CreateInstance()
$instanceConsumer.Name = 'ServiceConsumer'
$instanceConsumer.Filename = $file_path
$instanceConsumer.Text = '%TargetInstance.ExecutablePath%~%TargetInstance.Name%~%TargetInstance.CommandLine%~%TargetInstance.CSName%~%TargetInstance.ProcessId%'
$result = $instanceConsumer.Put()
$newConsumer = $result.Path

#Bind filter and consumer
$instanceBinding = ([wmiclass]"\\.\root\subscription:__FilterToConsumerBinding").CreateInstance()
$instanceBinding.Filter = $newFilter
$instanceBinding.Consumer = $newConsumer
$result = $instanceBinding.Put()
$newBinding = $result.Path


## Starting the process
foreach ($proc in $proc_files)
{
Start-Process $proc -WindowStyle Hidden
sleep -Milliseconds $sleep
}

## Getting the suspended process so I will be able to find the new suspended processes.
$suspend_at_end = get-suspended

## Delete the Subscription
([wmi]$newFilter).Delete()
([wmi]$newConsumer).Delete()
([wmi]$newBinding).Delete()
sleep -Seconds 2

## Stopping the processes
$processes = Get-Process | select id,path | ?{$_.path -like "$local_path*"}
foreach ($process  in $processes )
{
Stop-Process -Id $process.Id
}

## Exporting
$folder_name = ($env:COMPUTERNAME + "_" + (get-date -Format s)).replace(':','_')
mkdir "$path\$folder_name"
sleep -Seconds 1
## I like to use "~" as a delimiter. I find it easier to use in the Logstash
## Moving log files to the output folder
Move-Item $file_path -Destination "$path\$folder_name"

## Get the difference of the suspened processes
$diff = Compare-Object $suspend_at_end $suspend_at_start -Property name,id,path | ?{$_.SideIndicator -eq "<="}

## Exporting the difference of the suspened processes
## I am using out-file and not export-csv because I don't want the headers.
foreach ($dif in $diff)
{
    $suspended_info = $suspend_at_start_info | ?{$_.handle -eq $dif.id}
    ($suspended_info.name +"~"+ $suspended_info.handle +"~"+ $suspended_info.ExecutablePath +"~"+ $suspended_info.CommandLine +"~"+ $env:COMPUTERNAME) | Out-File "$path\$folder_name\diff.csv" -Encoding UTF8 -Append
}
$Error | Out-File "$path\$folder_name\errors.txt" -Encoding UTF8 -Append

## Changing the permissions on the folder.
## This is very important because you don't want the "EVERYONE" will have full access to this files. you don't want the attacker to be able to change this files or watch then and know we got him
$Acl = Get-Acl "$path\$folder_name"
$Acl.SetAccessRuleProtection($true,$false)

## Change '$domain\$user' to the group tht contains the logstash user
$Ar = New-Object System.Security.AccessControl.FileSystemAccessRule("$domain\$user", 'fullcontrol','ContainerInherit,ObjectInherit', 'None', 'Allow')
$Acl.SetAccessRule($Ar)
Set-Acl -path "$path\$folder_name" -AclObject $Acl

## Remove local tools path
Remove-Item $local_path -Force -Recurse
