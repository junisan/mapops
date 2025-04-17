FROM openjdk:17-slim

ARG PHOTON_VERSION=0.6.2
ENV PHOTON_VERSION=${PHOTON_VERSION}

WORKDIR /app

RUN apt-get update && \
    apt-get install -y wget && \
    rm -rf /var/lib/apt/lists/*

RUN wget -O photon.jar https://github.com/komoot/photon/releases/download/${PHOTON_VERSION}/photon-${PHOTON_VERSION}.jar

ENV DB_HOST=nominatim
ENV DB_PORT=5432
ENV DB_NAME=nominatim
ENV DB_USER=nominatim
ENV DB_PASSWORD=nominatim

ENTRYPOINT [ "bash", "-c", "\
  if [ \"$1\" = \"import\" ]; then \
    java -jar photon.jar \
      -data-dir /photon \
      -nominatim-import \
      -host $DB_HOST \
      -port $DB_PORT \
      -database $DB_NAME \
      -user $DB_USER \
      -password $DB_PASSWORD \
      -languages de,en,fr,es && \
      echo '✅ Imported. Exiting'; \
  else \
    java -jar photon.jar -data-dir /photon; \
  fi", "bash" ]
