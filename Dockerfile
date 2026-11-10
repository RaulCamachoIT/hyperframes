# HyperFrames Studio — imagen de servicio del panel (T-364).
#
# Construye el monorepo con la misma versión de bun que fija
# package.json#engines (1.4.4) y sirve el studio con `hyperframes preview`
# sobre un proyecto de demostración. El render MP4 funciona dentro del
# contenedor: incluye chrome-headless-shell y ffmpeg/ffprobe fijados.
#
# Build (contexto = raíz del repo):
#   docker build -t ita-hyperframes:dev .
#   docker run --rm -p 3002:3002 ita-hyperframes:dev
#   curl -fsS http://127.0.0.1:3002/    # 200
#
# Tamaño/tiempo (host de 12 vCPU, docker 29, primera build en frío):
#   ~10-12 min de build y 2,63 GB de imagen (medido en T-364). El coste real
#   está en node_modules de producción (827 MB, workspaces con AWS SDK/GCP),
#   chrome-headless-shell (273 MB) y las libs de Chrome (402 MB). Se documenta
#   en deploy/README.md por qué no se recorta más.
#
# Lo que NO entra: adaptadores de render distribuido (AWS Lambda / GCP Cloud
# Run se construyen bajo demanda), la app de escritorio, y los paquetes de
# test/bench. Fuentes: set base (Liberation/DejaVu/Noto emoji + core); los
# sets CJK/extra (cientos de MB) se omiten y se pueden añadir si un proyecto
# los necesita.

ARG NODE_IMAGE=node:22.23.4-bookworm-slim
ARG BUN_VERSION=1.4.4
ARG CHROME_HEADLESS_SHELL_VERSION=152.0.7977.30

# ─────────────────────────────────────────────────────────────────────────────
# 1) Build del monorepo
# ─────────────────────────────────────────────────────────────────────────────
FROM ${NODE_IMAGE} AS build
ARG BUN_VERSION
ENV BUN_INSTALL=/usr/local/bun \
    PATH=/usr/local/bun/bin:${PATH}

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl unzip git \
    && rm -rf /var/lib/apt/lists/*

# Bun fijado: el repo compara engines.bun=1.4.4 y el lock se generó con ella.
RUN curl -fsSL https://bun.sh/install | bash -s "bun-v${BUN_VERSION}" \
    && test "$(bun --version)" = "${BUN_VERSION}"

WORKDIR /app

# Manifiestos de TODOS los workspaces: `bun install --frozen-lockfile`
# considera un miembro ausente como cambio de lockfile y falla.
COPY package.json bun.lock ./
COPY packages/aws-lambda/package.json packages/aws-lambda/package.json
COPY packages/cli/package.json packages/cli/package.json
COPY packages/core/package.json packages/core/package.json
COPY packages/engine/package.json packages/engine/package.json
COPY packages/gcp-cloud-run/package.json packages/gcp-cloud-run/package.json
COPY packages/inspector/package.json packages/inspector/package.json
COPY packages/lint/package.json packages/lint/package.json
COPY packages/parsers/package.json packages/parsers/package.json
COPY packages/player/package.json packages/player/package.json
COPY packages/producer/package.json packages/producer/package.json
COPY packages/sdk/package.json packages/sdk/package.json
COPY packages/sdk-playground/package.json packages/sdk-playground/package.json
COPY packages/shader-transitions/package.json packages/shader-transitions/package.json
COPY packages/share/package.json packages/share/package.json
# @hyperframes/share tiene `prepare: tsc -p tsconfig.json` y bun lo ejecuta en
# el install del builder: sin sus fuentes el install muere con TS5058. Es la
# misma precaución que packages/gcp-cloud-run/Dockerfile.
COPY packages/share/tsconfig.json packages/share/tsconfig.json
COPY packages/share/src/ packages/share/src/
COPY packages/share/scripts/ packages/share/scripts/
COPY packages/studio/package.json packages/studio/package.json
COPY packages/studio-server/package.json packages/studio-server/package.json

# Un tarball corrupto puede imprimir el error y quedarse colgado (visto en
# Dockerfile.test / run 35468046055). Se acota y se reintenta una vez.
RUN timeout 900 bun install --frozen-lockfile \
    || timeout 900 bun install --frozen-lockfile

COPY . .

# Orden mínimo para `hyperframes preview`: los paquetes que el studio-server y
# el CLI resuelven por `dist` (condición node) y el bundle de studio que
# build:copy mete en packages/cli/dist/studio. El build completo del monorepo
# (aws-lambda, gcp-cloud-run, sdk-playground) no hace falta para servir.
RUN bun run --filter '@hyperframes/{parsers,lint,studio-server,share}' build \
    && bun run --filter @hyperframes/core build \
    && bun run --filter '@hyperframes/{engine,producer,player,studio,shader-transitions,inspector}' build \
    && bun run --filter @hyperframes/cli build \
    && test -f packages/cli/dist/studio/index.html \
    && test -f packages/cli/bin/hyperframes.mjs

# ─────────────────────────────────────────────────────────────────────────────
# 2) chrome-headless-shell (captura determinista del render)
# ─────────────────────────────────────────────────────────────────────────────
FROM ${NODE_IMAGE} AS chrome
ARG CHROME_HEADLESS_SHELL_VERSION
# `unzip` es obligatorio: @puppeteer/browsers extrae el zip con él (sin el
# binario falla con «no zip archiver is available», visto en la primera
# build local de T-364).
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates unzip \
    && rm -rf /var/lib/apt/lists/* \
    && npx --yes @puppeteer/browsers@3.2.2 install \
         "chrome-headless-shell@${CHROME_HEADLESS_SHELL_VERSION}" \
         --path /opt/puppeteer \
    && CHS="$(find /opt/puppeteer/chrome-headless-shell -name chrome-headless-shell -type f | head -n1)" \
    && test -n "$CHS" \
    && mkdir -p /opt/chrome \
    && ln -s "$CHS" /opt/chrome/chrome-headless-shell \
    && ls -l /opt/chrome/chrome-headless-shell

# ─────────────────────────────────────────────────────────────────────────────
# 3) Runtime: libs de Chrome, ffmpeg fijado, CLI construido y usuario no-root
# ─────────────────────────────────────────────────────────────────────────────
FROM ${NODE_IMAGE} AS runtime
ARG TARGETARCH
ARG FFMPEG_RELEASE=https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-02-28-12-59
ARG FFMPEG_BUILD=ffmpeg-n8.0.1-66-g27b8d1a017
ARG FFMPEG_SHA256_AMD64=26d2ecd0cefba99f9d1ea92252a3a4f743a58df4c1c3cf9f8bbaaa40b1fca5b0
ARG FFMPEG_SHA256_ARM64=d72cc324cb65dd92a9ffe699cc95ccbacfef4def8d3ad9fe2b5164a6a71b9595

ENV DEBIAN_FRONTEND=noninteractive
# Mismo set que Dockerfile.test/packages-gcp-cloud-run, sin GTK (headless shell)
# y sin los sets de fuentes CJK/extra (tamaño). Ver deploy/README.md.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils tini \
      libnss3 libnspr4 libgbm1 libasound2 libatk1.0-0 libatk-bridge2.0-0 \
      libcups2 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 \
      libxrandr2 libx11-6 libxcb1 libxext6 libxshmfence1 libatspi2.0-0 \
      libpango-1.0-0 libcairo2 libglib2.0-0 libdbus-1-3 libexpat1 \
      fonts-liberation fonts-dejavu-core fonts-noto-color-emoji fontconfig \
    && rm -rf /var/lib/apt/lists/* \
    && fc-cache -f

# FFmpeg estático fijado (misma build que la imagen de render del productor).
RUN case "$TARGETARCH" in \
      amd64) FF_ARCH=linux64; FF_SHA256="$FFMPEG_SHA256_AMD64" ;; \
      arm64) FF_ARCH=linuxarm64; FF_SHA256="$FFMPEG_SHA256_ARM64" ;; \
      *) echo "unsupported TARGETARCH '$TARGETARCH'" >&2; exit 1 ;; \
    esac \
    && curl -fsSL -o /tmp/ffmpeg.tar.xz "$FFMPEG_RELEASE/$FFMPEG_BUILD-$FF_ARCH-gpl-8.0.tar.xz" \
    && echo "$FF_SHA256  /tmp/ffmpeg.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/ffmpeg.tar.xz -C /usr/local/bin --strip-components=2 \
         --wildcards '*/bin/ffmpeg' '*/bin/ffprobe' \
    && rm /tmp/ffmpeg.tar.xz \
    && ffmpeg -version | grep -F "ffmpeg version ${FFMPEG_BUILD#ffmpeg-}" \
    && ffprobe -version | grep -F "ffprobe version ${FFMPEG_BUILD#ffmpeg-}"

COPY --from=chrome /opt/puppeteer /opt/puppeteer
COPY --from=chrome /opt/chrome /opt/chrome
# Solo el binario: en el builder, BUN_INSTALL=/usr/local/bun incluye la caché
# de `bun install` (~1,9 GB). Copiar el directorio entero inflaba la imagen.
COPY --from=build /usr/local/bun/bin/bun /usr/local/bin/bun

ENV PATH=/usr/local/bin:${PATH} \
    HOME=/data/home \
    NODE_ENV=production \
    PORT=3002 \
    HYPERFRAMES_PREVIEW_HOST=0.0.0.0 \
    HYPERFRAMES_BROWSER_PATH=/opt/chrome/chrome-headless-shell \
    PRODUCER_HEADLESS_SHELL_PATH=/opt/chrome/chrome-headless-shell \
    PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true \
    HYPERFRAMES_NO_TELEMETRY=1 \
    CONTAINER=true

WORKDIR /app

# node_modules de producción (solo manifiestos + lock; los dist vienen del
# builder). --ignore-scripts evita los `prepare` de los workspaces, que
# compilan TypeScript y aquí no aportan nada.
COPY package.json bun.lock ./
COPY packages/aws-lambda/package.json packages/aws-lambda/package.json
COPY packages/cli/package.json packages/cli/package.json
COPY packages/core/package.json packages/core/package.json
COPY packages/engine/package.json packages/engine/package.json
COPY packages/gcp-cloud-run/package.json packages/gcp-cloud-run/package.json
COPY packages/inspector/package.json packages/inspector/package.json
COPY packages/lint/package.json packages/lint/package.json
COPY packages/parsers/package.json packages/parsers/package.json
COPY packages/player/package.json packages/player/package.json
COPY packages/producer/package.json packages/producer/package.json
COPY packages/sdk/package.json packages/sdk/package.json
COPY packages/sdk-playground/package.json packages/sdk-playground/package.json
COPY packages/shader-transitions/package.json packages/shader-transitions/package.json
COPY packages/share/package.json packages/share/package.json
COPY packages/studio/package.json packages/studio/package.json
COPY packages/studio-server/package.json packages/studio-server/package.json
# HOME temporal: bun deja ~800 MB de caché en $HOME/.bun. Con el HOME real
# (/data/home) esa caché acababa dentro de la imagen y se perdía en el
# emptyDir del pod; se instala con un HOME en /tmp y se borra al terminar.
RUN mkdir -p /tmp/bun-home \
    && HOME=/tmp/bun-home timeout 600 bun install --production --frozen-lockfile --ignore-scripts \
    && rm -rf /tmp/bun-home

# Solo el CLI (bundle con studio, studio-server, core, producer y runtime).
COPY --from=build /app/packages/cli/package.json packages/cli/package.json
COPY --from=build /app/packages/cli/bin packages/cli/bin
COPY --from=build /app/packages/cli/dist packages/cli/dist

# Proyecto de demostración + entrypoint. /data es emptyDir en k8s: el pod
# arranca con el demo y cualquier edición se pierde al recrearlo (documentado).
COPY deploy/demo /opt/hyperframes-demo
COPY deploy/docker-entrypoint.sh /usr/local/bin/hyperframes-entrypoint

RUN groupadd --gid 10001 hyperframes \
    && useradd --uid 10001 --gid 10001 --home-dir /data/home --shell /usr/sbin/nologin hyperframes \
    && mkdir -p /data/home /data/project \
    && chown -R 10001:10001 /data \
    && chmod 0755 /usr/local/bin/hyperframes-entrypoint

USER 10001:10001
EXPOSE 3002

HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=3 \
  CMD curl -fsS http://127.0.0.1:3002/ >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/hyperframes-entrypoint"]
