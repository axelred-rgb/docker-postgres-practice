# Partiamo da un sistema operativo Linux minimo e pulito
FROM debian:bullseye-slim

# Installiamo i programmi che servono ai tuoi script per funzionare
RUN apt-get update && apt-get install -y curl uuid-runtime procps && rm -rf /var/lib/apt/lists/*

# Creiamo una cartella di lavoro all'interno dell'immagine
WORKDIR /app

# Copiamo i nostri due script dal computer all'interno dell'immagine, nella cartella /app
COPY agent_logic.sh .
COPY agent.sh .

# Rendiamo il nostro script principale eseguibile
RUN chmod +x agent.sh
