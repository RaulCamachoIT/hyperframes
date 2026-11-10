#!/bin/sh
# Entrypoint del contenedor de HyperFrames Studio (T-364).
#
# - Prepara $HOME y el proyecto en volúmenes escribibles (en k8s /data es un
#   emptyDir; la imagen tiene el filesystem raíz de solo lectura).
# - Si el proyecto está vacío, copia el demo de la imagen.
# - Arranca `hyperframes preview` en foreground y sin abrir navegador.
#   El bind 0.0.0.0 lo fija HYPERFRAMES_PREVIEW_HOST (por defecto el CLI
#   escucha solo en 127.0.0.1, inútil dentro de un pod).
set -eu

PROJECT_DIR="${HYPERFRAMES_PROJECT_DIR:-/data/project}"
PORT="${PORT:-3002}"

mkdir -p "$PROJECT_DIR" "$HOME/.local/state/hyperframes" "$HOME/.cache" /tmp

if [ ! -f "$PROJECT_DIR/index.html" ]; then
  echo "[hyperframes] proyecto vacío en $PROJECT_DIR; copiando demo de la imagen"
  cp -a /opt/hyperframes-demo/. "$PROJECT_DIR"/
fi

echo "[hyperframes] bun $(bun --version) · chrome $(/opt/chrome/chrome-headless-shell --version 2>/dev/null || echo '?')"
echo "[hyperframes] ffmpeg $(ffmpeg -version | head -n1)"
echo "[hyperframes] sirviendo $PROJECT_DIR en 0.0.0.0:$PORT"

exec bun /app/packages/cli/bin/hyperframes.mjs preview "$PROJECT_DIR" \
  --port "$PORT" --foreground --no-open
