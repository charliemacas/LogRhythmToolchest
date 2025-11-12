check_warm_capacity_v3.4.sh -- written by David O'Rourke LR Support 2025

# Purpose:
Produces a capacity and health report for Warm tier storage in a LogRhythm DX cluster. LogRhythm Users with a DX Cluster containing Warm Nodes can use the report to make better informed decisions on their warm retention capacity, and whether their shard count could be affecting their indexing rate.

The shard threshold formula used within the script is based off the Elasticsearch Shards Per Node threshold graph found in 7.22 LR Release in Grafana. To note, if the threshold is breached, indexing new data can be impaired.

# Requirements:
LogRhythm DX Cluster with Warm Node(s) accessible from the host running the script
bc installed for floating-point calculations

If not installed: 
sudo yum install -y bc

How to Run:

# Basic usage with retention days
sudo sh check_ultrawarm_capacity_v3.4.sh <retention_days>

NOTE: retention_days is user inputted - try provide the current warm/ultra-warm TTL (which can be found in LogRhythm Confurugation Manager)

# With detailed output for all warm indices
sudo sh check_warm_capacity_v3.4.sh --details <retention_days>

examples:
sudo sh check_warm_capacity_v3.4.sh 182
sudo sh check_warm_capacity_v3.4.sh --details 182

# Output

Warm nodes detected: Lists all warm nodes
Days Retention: Input retention period
Hot Nodes / Warm Nodes: Node counts
Total Shards / Load per Warm Node: Cluster shard distribution and per-node load
Heap (avg %): Average JVM heap usage for warm nodes
Disk Free (avg GB / %): Average available disk space
Average Warm Index Size: Average size of warm indices
Estimated Capacity: Number of additional indices warm nodes can hold
Detailed warm index sizes: (Optional with --details)
Warnings: Shard/heap or disk warnings if thresholds are exceeded
Estimated Max Safe Retention: Number of days the warm nodes can safely retain indices

# Example Output

```bash

Warm nodes detected:
lrs-dist-dx04
────────────────────────────────────
Days Retention (input):        182
Hot Nodes:                     3
Warm Nodes:                    1
Total Shards:                  92
Heap (avg %):                  67
Load per Warm Node:            92 (threshold: 2500)
────────────────────────────────────
Disk usage per warm node:
lrs-dist-dx04 → 97.8gb free (42% free)
Disk Free (avg per node):      97 GB
Disk Free (avg %):             42%
Average Warm Index Size:       4.74 GB
Estimated Capacity (disk):     20 more indices
────────────────────────────────────
Detailed warm index sizes:
logs-2025-11-08   4.6gb
logs-2025-11-09   5.7gb
logs-2025-11-10   5.5gb
logs-2025-11-11   5.8gb
logs-2025-11-12   2.1gb
────────────────────────────────────
SAFE (Shard/Heap load under threshold)
DISK OK: Sufficient disk on warm nodes
────────────────────────────────────
Estimated Max Safe Retention (disk-based): ~20 days
Warm node capacity check complete.
────────────────────────────────────

