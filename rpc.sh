#!/bin/bash
# Start command: sudo /bin/bash snap.sh

read -p "Enter sleep time (sec): " SLEEP
echo "export SLEEP=$SLEEP"

# Read from 'snap.conf'
PROJECT=$(awk -F/ '/link:/ {print $4}' snap.conf)
TYPE=$(sed -n "/link:/s/.*https:\/\/\([^\.]*\)\..*/\1/p" snap.conf)
PR_USER=$(sed -n "/prHome:/s/.*'\([^']*\)'.*/\1/p" snap.conf | awk -F/ '{print $NF}')
SERVICE=$(sed -n "/bin:/s/.*'\([^']*\)'.*/\1/p" snap.conf)
BIN=$(sed -n "/binHome:/s/.*'\([^']*\)'.*/\1/p" snap.conf)
PORT=$(sed -n "/port:/s/.*'\([^']*\)'.*/\1/p" snap.conf)
RPC="https://${PROJECT}-${TYPE}-rpc.itrocket.net:443"
PEERID=$(sed -n "/peerID:/s/.*'\([^']*\)'.*/\1/p" snap.conf)
PEERPORT=$(sed -n "/peerPort:/s/.*'\([^']*\)'.*/\1/p" snap.conf)
PEERS=${PEERID}@${PROJECT}-${TYPE}-peer.itrocket.net:${PEERPORT}
snapMaxSize=$(sed -n "/snapMaxSize:/s/.*'\([^']*\)'.*/\1/p" snap.conf)
PR_PATH=$(sed -n "/path:/s/.*'\([^']*\)'.*/\1/p" snap.conf)
NODE_PATH=/home/${PR_USER}/${PR_PATH}/
RESET=$(sed -n "/reset:/s/.*'\([^']*\)'.*/\1/p" snap.conf)
rpcStatus=$(sed -n "/rpcStatus:/s/.*'\([^']*\)'.*/\1/p" snap.conf)

# Check folder on the file server
PUBLIC_FOLDER=/var/www/$TYPE-files/$PROJECT
if [ -d "$PUBLIC_FOLDER" ]; then
    echo "$PUBLIC_FOLDER folder exists."
else
    mkdir /var/www/$TYPE-files/$PROJECT
    echo "$PUBLIC_FOLDER folder created."
fi

# Function  check_rpc_connection
check_rpc_connection() {
    if curl -s "$RPC" | grep -q "height" > /dev/null; then
        PARENT_NETWORK=$(curl -s "$RPC/status" | jq -r '.result.node_info.network')
        return 0
    else
        return 1
    fi
}

# Function fetch_data 
echo "RPC scanner started..."
fetch_data() {
    local url=$1
    local data=$(curl -s --max-time 2 "$url")
    
    if [ $? -ne 0 ]; then
        echo "Error: Failed to fetch data from $url"
        return 1
    fi
    
    echo "$data"
    return 0
}


declare -A processed_rpc
declare -A rpc_list

# Function process_data_rpc_list
process_data_rpc_list() {
    local data=$1

    if [ -z "$data" ]; then
        echo "Warning: No data to process."
        return 1
    fi

    local peers=$(echo "$data" | jq -c '.result.peers[]')
    if [ $? -ne 0 ]; then
        echo "Error: Failed to parse JSON data."
        return 1
    fi

    for peer in $peers; do
        rpc_address=$(echo "$peer" | jq -r '.node_info.other.rpc_address')
        if [[ $rpc_address == *"tcp://0.0.0.0:"* ]]; then
            ip=$(echo "$peer" | jq -r '.remote_ip // ""')
            port=${rpc_address##*:}
            rpc_combined="$ip:$port"
            temp_key="$rpc_combined"
            echo "Debug: rpc_combined = $rpc_combined"
            rpc_list["${temp_key}"]="{ \"rpc\": \"$rpc_combined\" }"

            if [[ -z ${processed_rpc["$rpc_combined"]} ]]; then
                processed_rpc["$rpc_combined"]=1
                echo "Processing new RPC: $rpc_combined" 
                new_data=$(fetch_data "http://$rpc_combined/net_info")
                if [ $? -eq 0 ]; then
                    process_data_rpc_list "$new_data"
                else
                    echo "Warning: Skipping $rpc_combined due to fetch error."
                fi
            fi
        fi
    done
}

# Function check_rpc_accessibility
check_rpc_accessibility() {
    local rpc=$1
    if [[ $rpc == http://* ]]; then
        protocol="http"
        rpc=${rpc#http://}
    elif [[ $rpc == https://* ]]; then
        protocol="https"
        rpc=${rpc#https://}
    else
        protocol="http"
    fi

    local status_data=$(fetch_data "$protocol://$rpc/status")
    if [[ $? -ne 0 ]]; then
        echo "Error: Unable to fetch status data from $rpc"
        return 1
    fi

    local rpc_network=$(echo "$status_data" | jq -r '.result.node_info.network' 2>/dev/null)
    if [[ "$rpc_network" == "$PARENT_NETWORK" ]]; then
        return 0 
    else
        echo "Warning: Network mismatch for $rpc. Expected: $PARENT_NETWORK, Found: $rpc_network"
        return 1
    fi
}

# Starting collect public RPCs
if check_rpc_connection; then
    public_data=$(fetch_data "$RPC/net_info")
    process_data_rpc_list "$public_data" "$PARENT_NETWORK"
    echo PARENT_NETWORK = $PARENT_NETWORK
fi

# Creating and populating the rpc_combined.json file
FILE_PATH_JSON="/home/$PR_USER/snap/rpc_combined.json"
PUBLIC_FILE_JSON="/var/www/$TYPE-files/$PROJECT/.rpc_combined.json"

# If the file exists, clear it. If not, create it.
[[ -f $FILE_PATH_JSON ]] && > "$FILE_PATH_JSON" || touch "$FILE_PATH_JSON"

# Start the JSON file by opening an object
echo "{" > $FILE_PATH_JSON

# Variable for determining the first entry to avoid adding a comma before the first object
first_entry=true

# Loop to read each line from the RPC list
for rpc in "${!rpc_list[@]}"; do
    if check_rpc_accessibility "$rpc"; then
        data=$(fetch_data "$rpc/status")
        network=$(echo "$data" | jq -r '.result.node_info.network')
        moniker=$(echo "$data" | jq -r '.result.node_info.moniker')
        tx_index=$(echo "$data" | jq -r '.result.node_info.other.tx_index')
        latest_block_height=$(echo "$data" | jq -r '.result.sync_info.latest_block_height')
        earliest_block_height=$(echo "$data" | jq -r '.result.sync_info.earliest_block_height')
        catching_up=$(echo "$data" | jq -r '.result.sync_info.catching_up')
        voting_power=$(echo "$data" | jq -r '.result.validator_info.voting_power')
        scan_time=$(date '+%FT%T.%N%Z')

        if [ "$first_entry" = true ]; then
            first_entry=false
        else
            echo "," >> $FILE_PATH_JSON
        fi

        echo -ne "  \"$rpc\": {\n    \"network\": \"$network\",\n    \"moniker\": \"$moniker\",\n    \"tx_index\": \"$tx_index\",\n    \"latest_block_height\": \"$latest_block_height\",\n    \"earliest_block_height\": \"$earliest_block_height\",\n    \"catching_up\": $catching_up,\n    \"voting_power\": \"$voting_power\",\n    \"scan_time\": \"$scan_time\"\n  }" >> $FILE_PATH_JSON
    fi
done

# Closing the JSON object
echo "}" >> $FILE_PATH_JSON

# Copying the JSON file to a public location
sudo cp $FILE_PATH_JSON $PUBLIC_FILE_JSON

# Uncomment the following line if you want to see the file content
# cat $PUBLIC_FILE_JSON
