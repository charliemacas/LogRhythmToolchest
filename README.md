# LogRhythmToolchest

A collection of resources you can leverage to improve the functionality of a LogRhythm SIEM. A few examples of the type of thing this resource contains; 

- Pre-built MITRE AIE Rule
- Advanced Reporting e.g. Grafana & Kibana Resources
- Threat Intellgience Integrations / Resources
- Scripts For Platform Management
- Scripts For Custom Integrations

 # How To Download Stuff From This Repository (To be adjusted to contain specific URL's not just examples)

(Download Everything Via Powershell)

Invoke-WebRequest -Uri "https://github.com/USERNAME/REPO/archive/refs/heads/BRANCH.zip" -OutFile "repo.zip"
Expand-Archive -Path "repo.zip" -DestinationPath "."

(Download Individual Files)

Invoke-WebRequest -Uri "https://raw.githubusercontent.com/USERNAME/REPO/BRANCH/PATH/TO/FILE" -OutFile "localfile.ext"

Invoke-WebRequest -Uri "https://raw.githubusercontent.com/octocat/Hello-World/main/README.md" -OutFile "README.md"
