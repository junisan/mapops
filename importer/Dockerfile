FROM eclipse-temurin:21-jdk AS builder

ARG PHOTON_VERSION=1.3.0
# sha256 of the asset published on GitHub Releases (see the release's digest)
ARG PHOTON_SHA256=a89707c0045e4807b2a1180e132e68e108d998709f48b6c94b98a6e281f571a5
WORKDIR /build


RUN apt-get update && \
    apt-get install -y wget ca-certificates && \
    wget -O photon.jar https://github.com/komoot/photon/releases/download/${PHOTON_VERSION}/photon-${PHOTON_VERSION}.jar && \
    echo "${PHOTON_SHA256}  photon.jar" | sha256sum -c -

COPY PhotonLauncher.java .
RUN javac PhotonLauncher.java && \
    jar cfe launcher.jar PhotonLauncher PhotonLauncher.class && \
    mkdir -p /build/photon

# Static wget (busybox) so the distroless image supports healthchecks
FROM busybox:stable-musl AS busybox

###
FROM gcr.io/distroless/java21-debian12

LABEL org.opencontainers.image.source="https://github.com/junisan/mapops" \
      org.opencontainers.image.description="Photon geocoder (OpenSearch) with a launcher that imports from a Nominatim database" \
      org.opencontainers.image.licenses="GPL-3.0"

USER nonroot
WORKDIR /app

COPY --from=busybox /bin/busybox /usr/bin/wget
COPY --from=builder --chown=nonroot:nonroot /build/photon.jar /app/photon.jar
COPY --from=builder --chown=nonroot:nonroot /build/launcher.jar /app/launcher.jar
COPY --from=builder --chown=nonroot:nonroot /build/photon /photon

# DB_PASSWORD always comes from the env_file (no default baked into the image)
ENV DB_HOST=nominatim \
    DB_PORT=5432 \
    DB_NAME=nominatim \
    DB_USER=nominatim \
    PHOTON_LANGUAGES=de,en,fr,es

ENTRYPOINT ["java", "-jar", "/app/launcher.jar"]
