#!/bin/bash
# ================================================================
# LogRhythm DX Warm Node Capacity Check v3.4 - written by David O'Rourke LR Support
# Correct warm node detection, optional --details flag
# ================================================================

set -e

ES="localhost:9200"
SAFE_THRESHOLD=2500

# ---------------------------
# Parse arguments
# ---------------------------
DETAILS=0
while [[ "$1" != "" ]]; do
    case $1 in
        --details ) DETAILS=1 ;;
        * ) RETENTION_DAYS=$1 ;;
    esac
    shift
done

if [ -z "$RETENTION_DAYS" ]; then
  echo "Usage: $0 [--details] <retention_days>"
  exit 1
fi

if ! command -v bc >/dev/null 2>&1; then
  echo "'bc' is required but not installed. Please install it. See Readme.md for instruction."
  exit 1
fi

echo "Collecting Elasticsearch stats..."
echo "────────────────────────────────────"

# ---------------------------
# Detect hot and warm nodes
# ---------------------------
HOT_COUNT=$(curl -s "$ES/_nodes?filter_path=nodes.*.attributes.box_type" \
  | tr '{' '\n' \
  | grep '"box_type":"hot"' \
  | wc -l)

# Robust warm node detection
WARM_NODES=$(curl -s "$ES/_nodes?filter_path=nodes.*.name,nodes.*.attributes.box_type" \
  | tr '{' '\n' \
  | grep '"name":\|"box_type":' \
  | awk -F'"' '
      /"name":/ {name=$4}
      /"box_type":"warm"/ {print name}
  ')

WARM_COUNT=$(echo "$WARM_NODES" | grep -c .)

if [ "$WARM_COUNT" -eq 0 ]; then
  echo "No warm nodes detected."
  exit 1
fi

echo "Warm nodes detected:"
echo "$WARM_NODES"
echo "────────────────────────────────────"

# ---------------------------
# Heap stats for warm nodes
# ---------------------------
AVG_HEAP=$(curl -s "$ES/_cat/nodes?h=name,heap.percent" \
  | grep -Ff <(echo "$WARM_NODES") | awk '{sum+=$2; c++} END {if(c>0) print sum/c; else print 0}')

# ---------------------------
# Total shards and load
# ---------------------------
TOTAL_SHARDS=$(curl -s "$ES/_cat/shards?h=index" | wc -l)
LOAD_PER_WARM=$(echo "$TOTAL_SHARDS / $WARM_COUNT" | bc)

echo "Days Retention (input):        $RETENTION_DAYS"
echo "Hot Nodes:                     $HOT_COUNT"
echo "Warm Nodes:                    $WARM_COUNT"
echo "Total Shards:                  $TOTAL_SHARDS"
echo "Heap (avg %):                  $AVG_HEAP"
echo "────────────────────────────────────"
echo "Load per Warm Node:            $LOAD_PER_WARM (threshold: $SAFE_THRESHOLD)"

# ---------------------------
# Disk info per warm node
# ---------------------------
echo "────────────────────────────────────"
echo "Disk usage per warm node:"
TOTAL_DISK_FREE=0
for NODE in $WARM_NODES; do
  DISK_AVAIL=$(curl -s "$ES/_cat/allocation?v" | awk -v node="$NODE" '$9==node {print $5}')
  # Convert GB/TB to numeric GB
  if [[ "$DISK_AVAIL" == *gb ]]; then
    VALUE=${DISK_AVAIL%gb}
  elif [[ "$DISK_AVAIL" == *tb ]]; then
    VALUE=$(echo "${DISK_AVAIL%tb}*1024" | bc)
  else
    VALUE=0
  fi
  echo "$NODE → $DISK_AVAIL free"
  TOTAL_DISK_FREE=$(echo "$TOTAL_DISK_FREE + $VALUE" | bc)
done
AVG_DISK_FREE=$(echo "$TOTAL_DISK_FREE / $WARM_COUNT" | bc)

# ---------------------------
# Warm index sizes
# ---------------------------
INDEX_SIZES=$(curl -s "$ES/_cat/indices?h=index,store.size" | grep '^logs-')
AVG_INDEX_SIZE=$(echo "$INDEX_SIZES" | awk '
  /gb$/ {sub("gb","",$2); sum+=$2; count++}
  /mb$/ {sub("mb","",$2); sum+=($2/1024); count++}
  END {if(count>0) print sum/count; else print 0}')

ESTIMATED_CAPACITY=0
if (( $(echo "$AVG_INDEX_SIZE > 0" | bc -l) )); then
  ESTIMATED_CAPACITY=$(echo "$AVG_DISK_FREE / $AVG_INDEX_SIZE" | bc)
fi

# ---------------------------
# Output
# ---------------------------
echo "Disk Free (avg per node):      ${AVG_DISK_FREE} GB"
echo "Average Warm Index Size:       ${AVG_INDEX_SIZE} GB"
echo "Estimated Capacity (disk):     $ESTIMATED_CAPACITY more indices"
echo "────────────────────────────────────"

# Optional detailed index list
if [ "$DETAILS" -eq 1 ]; then
  echo "Detailed warm index sizes:"
  echo "$INDEX_SIZES" | sort
  echo "────────────────────────────────────"
fi

# ---------------------------
# Health checks
# ---------------------------
if (( $(echo "$LOAD_PER_WARM > $SAFE_THRESHOLD" | bc -l) )); then
  echo "WARNING: Shard/heap load above safe threshold!"
else
  echo "SAFE (Shard/Heap load under threshold)"
fi

if (( $(echo "$AVG_DISK_FREE / $TOTAL_DISK * 100 < 15" | bc -l) )); then
  echo "DISK WARNING: Low disk space (<15%) on warm nodes"
else
  echo "DISK OK: Sufficient disk on warm nodes"
fi

# Estimated max safe retention (disk-based)
EST_MAX_DAYS=$(echo "$ESTIMATED_CAPACITY" | bc)
echo "────────────────────────────────────"
echo "Estimated Max Safe Retention (disk-based): ~${EST_MAX_DAYS} days"
echo "Warm node capacity check complete."
echo "────────────────────────────────────"
