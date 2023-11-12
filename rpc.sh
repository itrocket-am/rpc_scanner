#!/bin/bash
# Start command: sudo /bin/bash snap.sh

read -p "Enter sleep time (sec):" SLEEP
echo 'export SLEEP='$SLEEP

# read '${PROJECT}.json'
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
# Check pre_rpc file on the file server
PRE_FILE=/home/$PR_USER/snap/rpc_combined.txt

if [ -f "$PRE_FILE" ]; then
    echo "$PRE_FILE file exists."
else
    touch "$PRE_FILE"
    echo "$PRE_FILE file created."
fi

# add check_localhost_connection function
check_localhost_connection() {
    if curl -s --head localhost:${PORT}657 | head -n 1 | grep "200 OK" > /dev/null; then
        return 0
    else
        return 1
    fi
}

# add check_rpc_connection function
check_rpc_connection() {
    if curl -s "$RPC" | grep -q "height" > /dev/null; then
        return 0
    else
        return 1
    fi
}

# add fetch_data function
echo RPC scanner stated...
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

process_data_rpc_list() {
    local data=$1

    # проверка на пустые данные
    if [ -z "$data" ]; then
        echo "Warning: No data to process."
    return 1
  fi

  local peers=$(echo "$data" | jq -c '.result.peers[]')
    
    # проверка на ошибки jq
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

            # Если этот RPC еще не был обработан
      if [[ -z ${processed_rpc["$rpc_combined"]} ]]; then
                processed_rpc["$rpc_combined"]=1  # помечаем как обработанный
                echo "Processing new RPC: $rpc_combined" 
                
        new_data=$(fetch_data "http://$rpc_combined/net_info")
                
                # проверка успешности выполнения fetch_data
                if [ $? -eq 0 ]; then
                    process_data_rpc_list "$new_data"
                else
                    echo "Warning: Skipping $rpc_combined due to fetch error."
                fi
      fi
    fi
  done
}

# Функция для проверки доступности RPC на основе voting_power
check_rpc_accessibility() {
    local rpc=$1
    
    # Проверка протокола
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

    # Если запрос не удался
    if [[ $? -ne 0 ]]; then
        return 1  # недоступен
    fi

    local voting_power=$(echo "$status_data" | jq '.result.validator_info.voting_power' 2>/dev/null)

    # Если поле voting_power существует
    if [[ -n "$voting_power" ]]; then
        return 0  # доступен
    else
        return 1  # недоступен
    fi
}

#if check_localhost_connection; then
#    local_data=$(fetch_data "localhost:${PORT}/net_info")
#    process_data_rpc_list "$local_data" "None"  # "None" signifies no parent for the localhost

    if check_rpc_connection; then
        public_data=$(fetch_data "$RPC/net_info")
        process_data_rpc_list "$public_data" "$RPC"  # The parent here is whatever $RPC holds
    fi

# Обработка доступных RPC
    for rpc in "${!rpc_list[@]}"; do
        # Если RPC доступен
        if check_rpc_accessibility "$rpc"; then
            # Если отсутствует в $PRE_FILE - добавляем
            if ! grep -q "$rpc" "$PRE_FILE"; then
                echo "$rpc" >> "$PRE_FILE"
            fi
        fi
    done

#    # Создание временного файла для хранения проверенных RPC
    TEMP_FILE=$(mktemp)

# Обработка RPC из $PRE_FILE
while IFS= read -r line; do
    # Если RPC начинается с "https://", сохраняем независимо от доступности
    if [[ "$line" == https://* ]]; then
        echo "$line" >> "$TEMP_FILE"
    # В противном случае проверяем доступность или наличие в rpc_list
    elif check_rpc_accessibility "$line" || [[ -n ${rpc_list["$line"]} ]]; then
        echo "$line" >> "$TEMP_FILE"
    fi
done < "$PRE_FILE"

# Замена $PRE_FILE содержимым из TEMP_FILE
    mv "$TEMP_FILE" "$PRE_FILE"

# Опционально: вывод содержимого $PRE_FILE
    cat "$PRE_FILE"
#fi

# Создайте файл rpc_combined.json или очистите его, если он уже существует
FILE_PATH_JSON="/home/$PR_USER/snap/rpc_combined.json"
PUBLIC_FILE_JSON=/var/www/$TYPE-files/$PROJECT/.rpc_combined.json

# Если файл существует, очистите его. Если нет - создайте.
[[ -f $FILE_PATH_JSON ]] && > "$FILE_PATH_JSON" || touch "$FILE_PATH_JSON"

# Начинаем JSON с открытия объекта
echo "{" > $FILE_PATH_JSON

# Переменная для определения первой записи (чтобы избежать добавления запятой перед первым объектом)
first_entry=true

# Цикл для чтения каждой строки из файла $PRE_FILE
while IFS= read -r rpc; do
    # Проверка доступности RPC
    if check_rpc_accessibility "$rpc"; then
        # Извлечение данных с помощью функции fetch_data
        data=$(fetch_data "$rpc/status")
        
        # Извлекаем необходимые данные из ответа RPC
        network=$(echo "$data" | jq -r '.result.node_info.network')
        moniker=$(echo "$data" | jq -r '.result.node_info.moniker')
        tx_index=$(echo "$data" | jq -r '.result.node_info.other.tx_index')
        latest_block_height=$(echo "$data" | jq -r '.result.sync_info.latest_block_height')
        earliest_block_height=$(echo "$data" | jq -r '.result.sync_info.earliest_block_height')
        catching_up=$(echo "$data" | jq -r '.result.sync_info.catching_up')
        voting_power=$(echo "$data" | jq -r '.result.validator_info.voting_power')
        scan_time=$(date '+%FT%T.%N%Z')  # Текущая дата и время

        # Добавляем запятую перед следующим объектом, если это не первая запись
        if [ "$first_entry" = true ]; then
            first_entry=false
        else
            echo "," >> $FILE_PATH_JSON
        fi

       # Записываем извлеченные данные в файл
       echo -ne "  \"$rpc\": {\n    \"network\": \"$network\",\n    \"moniker\": \"$moniker\",\n    \"tx_index\": \"$tx_index\",\n    \"latest_block_height\": \"$latest_block_height\",\n    \"earliest_block_height\": \"$earliest_block_height\",\n    \"catching_up\": $catching_up,\n    \"voting_power\": \"$voting_power\",\n    \"scan_time\": \"$scan_time\"\n  }" >> $FILE_PATH_JSON
    fi
done < "$PRE_FILE"

# Закрываем объект в JSON
echo "}" >> $FILE_PATH_JSON

# Копируем JSON-файл в публичное место
sudo cp $FILE_PATH_JSON $PUBLIC_FILE_JSON

# Если хотите увидеть содержимое файла, раскомментируйте следующую строку
# cat $PUBLIC_FILE_JSON
systemctl restart ${PR_USER}-snap
