#!/bin/bash

# Esce immediatamente se un comando fallisce
set -e

# Include il file con la logica delle funzioni
source ./agent_logic.sh

echo "[INFO] Avvio dell'agente in modalità container..."

# Esegue le funzioni di setup iniziali
create_log_directory
# check_and_install_dependencies # Questa parte viene già eseguita dal Dockerfile
get_or_create_token
get_or_create_userId

# Avvia il loop orario in background. Può rimanere in background
# perché il loop successivo terrà attivo il container.
(
    while true; do
        echo "[INFO] Esecuzione raccolta dati oraria..."
        collect_and_send_hourly_data
        sleep 3600
    done
) &

# Avvia il loop frequente IN PRIMO PIANO.
# Questo diventa il processo principale del container e lo mantiene attivo.
echo "[INFO] Avvio loop di raccolta dati frequente (processo principale)..."
while true; do
    echo "[INFO] Esecuzione raccolta dati frequente..."
    collect_and_send_frequent_data
    sleep 30
done
