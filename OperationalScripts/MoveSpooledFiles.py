<#
.Description LogRhythm - Move files from one directory to another when the target directory is empty. Used to move spooled event or log files.
#>
#######################################
# Set default values (Change here for default fixed values):
$SourceDefault = 'D:\Program Files\LogRhythm\LogRhythm Mediator Server\state\DXReliablePersist.old' #- Location of spooled data (Where you are moving from)
$DestinationDefault = 'D:\Program Files\LogRhythm\LogRhythm Mediator Server\state\DXReliablePersist' #- Location of live state folder (Where you are moving to)
$FileLimitDefault = 2 #- Number of files to move per cycle
$SleepTimeDefault = 30 #-Time per cycle (Logs are moved once per cycle)
$DestinationMaxDefault = 2 #- Max number of spooled files in the live state folder at any time (no files will move if more than X files are already in the directory)
#######################################

# Prompts for non default\custom values to be entered:

# PLEASE DO NOT MODIFY THE CONTENTS BELOW, FOR FIXED VALUES USE THE SECTION ABOVE

#######################################
# Set custom Directory path for the source or press enter for default
# Value: "C:\Program Files\LogRhythm\LogRhythm Mediator Server\state\SpooledEvents_HOLD"  or  "C:\Program Files\LogRhythm\LogRhythm Mediator Server\state\SpooledLogs_HOLD"

If (($SourceCustom = Read-Host -Prompt "Press Enter for the default [$SourceDefault], or enter a new path") -eq '' -or $SourceCustom -eq $SourceDefault) {
    Write-Host -foregroundcolor "yellow" "You're using the default ""$SourceDefault"" Path."
    $Source = $SourceDefault
} Else {
    Write-Host -foregroundcolor "yellow" "You're using ""$SourceCustom"""
    $Source = $SourceCustom
}
# Set custom Directory path for the destination or press enter for default
# Values: "C:\Program Files\LogRhythm\LogRhythm System Monitor\state\processedlogs" or "C:\Program Files\LogRhythm\LogRhythm Mediator Server\state\SpooledLogs"
 
If (($DestinationCustom = Read-Host -Prompt "Press Enter for the default [$DestinationDefault], or enter a new path") -eq '' -or $DestinationCustom -eq $DestinationDefault) {
    Write-Host -foregroundcolor "yellow" "You're using the default ""$DestinationDefault"" Path."
    $Destination = $DestinationDefault
} Else {
    Write-Host -foregroundcolor "yellow" "You're using ""$DestinationCustom"""
    $Destination = $DestinationCustom
}
# Number of files to move from source to dest at a time.
# Values: Int, default is 5 
If (($FileLimitCustom = Read-Host -Prompt "How many files do you want to move per cycle?, or press Enter for the default [$FileLimitDefault]") -eq '' -or $FileLimitCustom -eq $FileLimitDefault) {
    Write-Host -foregroundcolor "yellow" "You're using the default value: ""$FileLimitDefault"""
    $FileLimit = $FileLimitDefault
} Else {
    Write-Host -foregroundcolor "yellow" "You're using ""$FileLimitCustom"""
    $FileLimit = $FileLimitCustom
}

# Number of seconds to sleep before looking to see if the dest directory is empty.
# Values: Int, default is 60
If (($SleepTimeCustom = Read-Host -Prompt "How often would you like to try and move files? (in seconds), or press Enter for the default [$SleepTimeDefault]") -eq '' -or $SleepTimeCustom -eq $SleepTimeDefault) {
    Write-Host -foregroundcolor "yellow" "You're using the default value: ""$SleepTimeDefault"""
    $SleepTime = $SleepTimeDefault
} Else {
    Write-Host -foregroundcolor "yellow" "You're using ""$SleepTimeCustom"""
    $SleepTime = $SleepTimeCustom
}
# Max number of files allowed in the destination folder before skipping a cycle:
# $destinationmax = Read-Host ("Please set max files allowed in destination folder (Prevents script overwhelming directory, suggested value:3)")
If (($DestinationMaxCustom = Read-Host -Prompt "Please set max files allowed in destination folder (Prevents script overwhelming directory) or use Reccomended Value:[$DestinationMaxDefault]") -eq '' -or $DestinationMaxCustom -eq $DestinationMaxDefault) {
    Write-Host -foregroundcolor "yellow" "You're using the default value: ""$DestinationMaxDefault""."
    $DestinationMax = $DestinationMaxDefault
} Else {
    Write-Host -foregroundcolor "yellow" "You're using ""$DestinationMaxCustom"""
    $DestinationMax = $DestinationMaxCustom
}

#######################################
#
# Do not change anything below this line
#
#######################################
$originationInfo = [System.IO.Directory]::GetFiles("$source")
Write-Host (Get-Date), "Files in HOLD:", $originationInfo.count -foregroundcolor "red" #Returns the count of all of the files in the directory

while ('$originationInfo.count -gt 0')
{

$destinationInfo = [System.IO.Directory]::GetFiles("$destination")
Write-Host (Get-Date), "Files in process:" $destinationInfo.count -foregroundcolor "yellow" #Returns the count of all of the files in the directory
If ($destinationInfo.count -lt $destinationmax) 
  {    
    $SrcCount = [System.IO.Directory]::GetFiles("$source")
    if ($SrcCount.count -lt 1)
       {
              Write-Host "***File Move Complete***" -foregroundcolor "white"
              exit
       }
       
       Write-Host (Get-Date), "Moving" $FileLimit "for processing." -foregroundcolor "green"
        
       #Destination for files 
       $PickupDirectory = Get-ChildItem -Path $Source | sort-object -Property LastWriteTime       
                    
        $Counter = 0 
        foreach ($file in $PickupDirectory) {     
        if ($Counter -ne $FileLimit)     
        {                
            Write-Host $file.FullName -foregroundcolor "green" #Output file fullname to screen                   
            Move-Item $file.FullName -destination $Destination         
            $Counter++         
            }   
        } 
       $originationInfo = [System.IO.Directory]::GetFiles("$source")
       Write-Host (Get-Date), "Files in HOLD:", $originationInfo.count -foregroundcolor "red"
  }
     Start-Sleep -s $SleepTime 
}
Exit 