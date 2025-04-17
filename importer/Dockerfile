FROM eclipse-temurin:17-jdk as builder

ARG PHOTON_VERSION=0.6.2
ENV PHOTON_VERSION=${PHOTON_VERSION}
WORKDIR /build


RUN apt-get update && \
    apt-get install -y wget ca-certificates && \
    wget -O photon.jar https://github.com/komoot/photon/releases/download/${PHOTON_VERSION}/photon-${PHOTON_VERSION}.jar

COPY PhotonLauncher.java .
RUN javac PhotonLauncher.java && \
    jar cfe launcher.jar PhotonLauncher PhotonLauncher.class && \
    mkdir -p /build/photon


###
FROM gcr.io/distroless/java17-debian11

USER nonroot
WORKDIR /app

COPY --from=builder --chown=nonroot:nonroot /build/photon.jar /app/photon.jar
COPY --from=builder --chown=nonroot:nonroot /build/launcher.jar /app/launcher.jar
COPY --from=builder --chown=nonroot:nonroot /build/photon /photon

ENV DB_HOST=nominatim \
    DB_PORT=5432 \
    DB_NAME=nominatim \
    DB_USER=nominatim \
    DB_PASSWORD=nominatim \
    PHOTON_LANGUAGES=de,en,fr,es

ENTRYPOINT ["java", "-jar", "/app/launcher.jar"]
