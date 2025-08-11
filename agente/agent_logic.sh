#!/bin/bash

# --- PARAMETRI CONFIGURABILI TRAMITE VARIABILI D'AMBIENTE ---
LOG_DIR="./data"
ENDPOINT_URL="https://konsolex-logs.onthecloud.srl/api/logs/server-logs"
AGENT_VERSION="9.1-swarm" # Versione aggiornata per riflettere il nuovo approccio

# Percorsi dell'host montati nel container. Usano un valore di default se la variabile non è impostata.
HOST_PROC_PATH="${HOST_PROC:-/proc}"
# Percorsi per i dati delle applicazioni, ora configurabili
MAIL_DIR_PATH="${MAIL_DATA_DIR:-/var/vmail}" # Includere lo "/" finale
WEBS_DIR_PATH="${WEBS_DATA_DIR:-/var/www}"

# --- FILE DI STATO ---
PID_FILE="$LOG_DIR/agent.pid"
TOKEN_FILE="$LOG_DIR/token.txt"
USERID_FILE="$LOG_DIR/userId.txt"
FREQUENT_OUTPUT="$LOG_DIR/frequent_output.json"
DAILY_OUTPUT="$LOG_DIR/daily_output.json"

# --- FUNZIONI DI BASE ---

create_log_directory() {
    if [[ ! -d $LOG_DIR ]]; then
        mkdir -p $LOG_DIR
    fi
}

check_and_install_dependencies() {
    # Questa funzione viene eseguita durante la build del Dockerfile, ma la lasciamo per coerenza.
    if ! command -v uuidgen &> /dev/null; then
        apt-get update && apt-get install -y uuid-runtime
    fi
    if ! command -v curl &> /dev/null; then
        apt-get update && apt-get install -y curl
    fi
}

get_or_create_token() {
    create_log_directory
    if [[ ! -f $TOKEN_FILE ]]; then
        token=$(uuidgen)
        echo $token > $TOKEN_FILE
    else
        token=$(cat $TOKEN_FILE)
    fi
}

get_or_create_userId() {
    create_log_directory
    if [[ ! -f $USERID_FILE ]]; then
        userId=$(uuidgen)
        echo $userId > $USERID_FILE
    else
        userId=$(cat $USERID_FILE)
    fi
}

# --- FUNZIONI DI RACCOLTA DATI (REFAKTORIZZATE) ---

# Funzione generica per ottenere la versione di un servizio Swarm
get_service_version() {
    local service_name=$1
    # Interroga l'API di Docker tramite il socket per l'immagine del servizio
    local service_image=$(docker service inspect "$service_name" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null)
    
    if [[ -n "$service_image" ]]; then
        # Estrae il tag (la versione) dopo i due punti
        echo "${service_image##*:}"
    else
        echo "Service not found"
    fi
}

# Funzione per ottenere le statistiche dei container (invariata, usa già l'API Docker)
get_container_stats_frequent() {
    if command -v docker &> /dev/null; then
        docker_stats=$(docker stats --no-stream --format '{{.Container}},{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}},{{.NetIO}},{{.BlockIO}},{{.PIDs}}')
        docker_json_frequent="["
        IFS=$'\n'
        for line in $docker_stats; do
            # ... (la logica interna rimane la stessa)
            container_id=$(echo $line | cut -d',' -f1); container_name=$(echo $line | cut -d',' -f2); cpu_usage=$(echo $line | cut -d',' -f3); mem_usage=$(echo $line | cut -d',' -f4 | cut -d'/' -f1 | xargs); mem_limit=$(echo $line | cut -d'/' -f4 | cut -d'/' -f2 | xargs); mem_usage_pc=$(echo $line | cut -d',' -f5); net_io=$(echo $line | cut -d',' -f6); block_io=$(echo $line | cut -d',' -f7); pids=$(echo $line | cut -d',' -f8)
            docker_json_frequent+="{\"container_id\": \"$container_id\",\"name_ct\": \"$container_name\",\"cpu_ct\": \"$cpu_usage\",\"mem_usage_ct\": \"$mem_usage\",\"limit_mem_ct\": \"$mem_limit\",\"mem_usage_ct_pc\": \"$mem_usage_pc\",\"net_io\": \"$net_io\",\"block_io\": \"$block_io\",\"pids\": \"$pids\"},"
        done
        docker_json_frequent=${docker_json_frequent%,}
        docker_json_frequent+="]"
    else
        docker_json_frequent="[]"
    fi
}

# Le altre funzioni di raccolta (daily, maildomain, websites, etc.) rimangono
# funzionalmente simili ma ora operano sui percorsi parametrizzati
get_websites_stats() {
    if [ -d "$WEBS_DIR_PATH" ]; then
        # La logica interna rimane la stessa ma usa WEBS_DIR_PATH
        website_stats=$(find "$WEBS_DIR_PATH" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -exec du -sh --dereference -m {} \; | awk -v dir="$WEBS_DIR_PATH" '{size=$1; sub("^"dir, "", $2); print $2 ":" size}')
        website_json="["
        IFS=$'\n'
        for line in $website_stats; do
            website_json+=$(echo '"'$line'"'),
        done
        website_json=${website_json%,}
        website_json+="]"
    else
        website_json="[]"
    fi
}


# --- FUNZIONE PRINCIPALE DI RACCOLTA ---

collect_and_send_frequent_data() {
    get_or_create_token
    get_or_create_userId

    # Ottiene le versioni dei servizi del nostro stack
    postgres_ver=$(get_service_version myapp_postgres)
    tomcat_ver=$(get_service_version myapp_tomcat)
    proxy_ver=$(get_service_version myapp_proxy)

    # Raccoglie metriche dall'host usando i percorsi montati
    hostname_value=$(hostname -f)
    ram_value=$(awk '/MemTotal|MemAvailable/ {mem[$1]=$2} END {printf "%.2f", (mem["MemTotal:"]-mem["MemAvailable:"])*100/mem["MemTotal:"]}' "$HOST_PROC_PATH/meminfo")
    cpu_value=$(awk '{u=$2+$4; t=$2+$4+$5; if (NR==1){u1=u; t1=t;} else print ($2+$4-u1) * 100 / (t-t1)}' <(grep 'cpu ' "$HOST_PROC_PATH/stat") <(sleep 1; grep 'cpu ' "$HOST_PROC_PATH/stat"))
    disk_usage=$(df -h --output=pcent /host | tail -n 1 | awk '{print $1}') # Assumendo che la radice dell'host sia montata in /host
    
    # Raccoglie statistiche Docker (la funzione è già pronta per questo)
    get_container_stats_frequent
    get_websites_stats # Esempio di funzione che usa percorsi parametrizzati

    # Creazione del file JSON
    # (Omettiamo i campi per i servizi non più monitorati come mysql, apache, etc.)
    echo "{" > $FREQUENT_OUTPUT
    echo "  \"agentVersion\": \"$AGENT_VERSION\"," >> $FREQUENT_OUTPUT
    echo "  \"hostname\": \"$hostname_value\"," >> $FREQUENT_OUTPUT
    echo "  \"userId\": \"$userId\"," >> $FREQUENT_OUTPUT
    echo "  \"token\": \"$token\"," >> $FREQUENT_OUTPUT
    echo "  \"cpu\": \"$cpu_value\"," >> $FREQUENT_OUTPUT
    echo "  \"ram\": \"$ram_value\"," >> $FREQUENT_OUTPUT
    echo "  \"disk\": \"$disk_usage\"," >> $FREQUENT_OUTPUT
    echo "  \"postgres_version\": \"$postgres_ver\"," >> $FREQUENT_OUTPUT
    echo "  \"tomcat_version\": \"$tomcat_ver\"," >> $FREQUENT_OUTPUT
    echo "  \"proxy_version\": \"$proxy_ver\"," >> $FREQUENT_OUTPUT
    echo "  \"site_logs\": $website_json," >> $FREQUENT_OUTPUT
    echo "  \"docker_stats\": $docker_json_frequent" >> $FREQUENT_OUTPUT
    echo "}" >> $FREQUENT_OUTPUT

    # Invia il JSON all'endpoint
    curl -s -X POST -H "Content-Type: application/json" -d @$FREQUENT_OUTPUT $ENDPOINT_URL > /dev/null 2>&1
}

# La funzione collect_and_send_hourly_data andrebbe adattata in modo simile...
collect_and_send_hourly_data() {
    # ... logica simile per la raccolta oraria ...
    echo "Raccolta oraria non ancora implementata in versione refactored."
}

