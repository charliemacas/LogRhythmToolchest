<#  

Charlie MacArthur - LogRhythm Services Consultant 

"Inactive Archive Script"

.SYNOPSIS  

    This script deletes folders older than a specified retention period based on folder names formatted as YYYYMMDD.

.NOTES  

    Ensure you run the script as admin (it will tell you if you forget). 

    Automation steps below via task scheduler. 

    Create a New in Task Scheduler:

    General Tab:
        Name the task (e.g., "Delete Folders Older Than Retention Period").
        Select "Run with highest privileges".

    Triggers Tab:
        Click "New" to create a new trigger.
        Set the schedule - Run Daily, Weekly etc 

    Actions Tab:
        Click "New" to create a new action.
        Set "Action" to "Start a program".
        In the "Program/script" field, enter powershell.
        In the "Add arguments (optional)" field, enter -File "C:\path\to\Script.ps1".

    Conditions and Settings Tabs:
        Adjust any additional settings as needed, then click "OK" to save the task. 

CHANGE THESE TWO VARIABLES - 

Path to monitor
The number of days to retain data

#>

$monitoredFolderPath = "D:\LogRhythmArchives\Inactive"
$retentionDays = 732  # Number of days to retain folders

# Function to get folders older than the retention period
function Get-OldFolders {
    param (
        [string]$folderPath,
        [int]$days
    )
    $dateThreshold = (Get-Date).AddDays(-$days)

    # Get all directories
    $directories = Get-ChildItem -Path $folderPath -Directory

    $oldFolders = @()
    foreach ($folder in $directories) {
        # Extract the YYYYMMDD part from the folder name
        if ($folder.Name -match '(\d{8})') {
            $folderDateString = $matches[1]
            $folderDate = [datetime]::ParseExact($folderDateString, "yyyyMMdd", $null)

            # Compare folder date to the threshold
            if ($folderDate -lt $dateThreshold) {
                $oldFolders += $folder
            }
        }
    }

    return $oldFolders
}

# Function to delete the old folders
function Delete-OldFolders {
    param (
        [string]$folderPath,
        [int]$days
    )
    try {
        $oldFolders = Get-OldFolders -folderPath $folderPath -days $days
        if ($oldFolders.Count -eq 0) {
            Write-Host "No folders older than $days days were found in $folderPath. Nothing to delete."
        } else {
            foreach ($folder in $oldFolders) {
                try {
                    Remove-Item -Path $folder.FullName -Recurse -Force -ErrorAction Stop
                    Write-Host "Deleted: $($folder.FullName)"
                }
                catch {
                    Write-Host "Error deleting $($folder.FullName): $($_.Exception.Message)"
                }
            }
        }
    }
    catch {
        Write-Host "Error retrieving folders: $($_.Exception.Message)"
    }
}

# Function to display the ASCII art banner
function Show-AsciiBanner {
    $banner = @"
 _                ____  _           _   _               
| |    ___   __ _|  _ \| |__  _   _| |_| |__  _ __ ___  
| |   / _ \ / _` | |_) | '_ \| | | | __| '_ \| '_ ` _ \ 
| |__| (_) | (_| |  _ <| | | | |_| | |_| | | | | | | | |
|_____\___/ \__, |_| \_\_| |_|\__, |\__|_|_|_|_| |_| |_| 
   / \   _ _|___/| |__ (_)_   |___/  |_   _|__   ___ | |
  / _ \ | '__/ __| '_ \| \ \ / / _ \   | |/ _ \ / _ \| |
 / ___ \| | | (__| | | | |\ V /  __/   | | (_) | (_) | |
/_/   \_\_|  \___|_| |_|_| \_/ \___|   |_|\___/ \___/|_|

"@
    Write-Host $banner
}

# Check if script is running as administrator
function Test-IsAdmin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Main script
if (-not (Test-IsAdmin)) {
    Write-Host "Script is not running as Administrator. Please run the script with administrative privileges."
    exit
}

# Show the ASCII Art Banner
Show-AsciiBanner

# Pause for 5 seconds before continuing
Write-Host "Searching directory...
" -ForegroundColor Cyan
Start-Sleep -Seconds 5

Write-Host "Monitoring folder: $monitoredFolderPath"
Write-Host "Retention period: $retentionDays days"

# Delete old folders based on retention period
Delete-OldFolders -folderPath $monitoredFolderPath -days $retentionDays
