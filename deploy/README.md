# HyperFrames Studio en el panel (dev)

T-364: el studio de HyperFrames corre como un servicio más del panel.

| Dato       | Valor                                                         |
| ---------- | ------------------------------------------------------------- |
| URL        | https://hyperframes.dev.itadaptativa.es                       |
| Imagen     | `registry.itadaptativa.es/ita-hyperframes:dev-<sha>`          |
| Puerto     | `3002` (`hyperframes preview`, bind `0.0.0.0` dentro del pod) |
| Health     | `GET /` → 200 (index del studio)                              |
| Deployment | `dev/hyperframes`, 1 réplica (`emptyDir`, sin HPA)            |
| Workflow   | `.github/workflows/deploy.yml` (push a `main` → dev)          |

Este proyecto trabaja en `main` (config `git-hyperframes`, T-360); el workflow
trata `main` como dev. `pre` y `pro` no están aprovisionados.

## Cómo se construye la imagen

`Dockerfile` multi-stage, con las versiones **fijadas**:

1. **build** — `node:22.23.4-bookworm-slim` + bun `1.4.4` (el `engines` del
   repo), `bun install --frozen-lockfile` y builds mínimos para servir el
   studio: `parsers`, `lint`, `studio-server`, `share`, `core`, `engine`,
   `producer`, `player`, `studio`, `shader-transitions`, `inspector`, `cli`.
   El bundle de studio queda en `packages/cli/dist/studio` (lo copia
   `build:copy`).
2. **chrome** — `chrome-headless-shell@152.0.7977.30` con
   `@puppeteer/browsers` en `/opt/chrome/chrome-headless-shell`.
3. **runtime** — libs de Chrome, ffmpeg/ffprobe estáticos BtbN fijados,
   `node_modules` de producción y solo `packages/cli` (bin + dist). Usuario
   `10001`, `HOME=/data/home`, `tini` como PID 1.

Arranque (`deploy/docker-entrypoint.sh`): si `/data/project` está vacío copia
el demo de la imagen (`deploy/demo`) y ejecuta:

```sh
bun /app/packages/cli/bin/hyperframes.mjs preview /data/project \
  --port 3002 --foreground --no-open
```

`HYPERFRAMES_PREVIEW_HOST=0.0.0.0` es obligatorio: el CLI escucha en
`127.0.0.1` por defecto (F-001) y el Service no lo alcanzaría.

### Tamaño y tiempo

Primera build en frío (medida en T-364, host de 12 vCPU): **~10-12 min** y
**2,63 GB** de imagen. El coste está en `node_modules` de producción (827 MB:
los workspaces arrastran AWS SDK/GCP aunque el preview no los use), Chrome
(273 MB + 402 MB de libs) y ffmpeg. Si hay que recortar:

- instalar solo las dependencias de `packages/cli` (≈90 MB) en una etapa sin
  workspaces: baja el tamaño pero pierde la reproducibilidad del `bun.lock`;
- usar una base con Chrome del sistema y omitir `chrome-headless-shell`
  (rompe la captura determinista del render);
- omitir ffmpeg si el servicio solo va a previsualizar (el render MP4 falla).

Se mantiene el `node_modules` de producción para respetar el lockfile.

## Terceros y variables

- **No hace falta ninguna credencial** para arrancar el studio y editar.
- `GEMINI_API_KEY` (opcional): captioning IA al capturar webs.
- `HEYGEN_API_KEY` / `HEYGEN_ACCESS_TOKEN` (opcional): funciones de media que
  hablan con la API de HeyGen.
- **AWS / GCP**: solo para render distribuido (`packages/aws-lambda`,
  `packages/gcp-cloud-run`). **No** se incluyen en esta imagen y no son
  necesarios para el studio ni para el render local.
- Telemetría desactivada (`HYPERFRAMES_NO_TELEMETRY=1`).
- El demo carga GSAP desde `cdn.jsdelivr.net`; sin salida a internet el
  studio sigue cargando y el timeline del demo queda estático.

## Render

El render local (el que hace el productor: Chrome headless captura frames y
ffmpeg codifica) funciona dentro de la imagen. Verificado en T-364 con el
proyecto demo (10 s, 30 fps, 300 frames, `--quality draft`, 1 worker):

```sh
docker exec <contenedor> bun /app/packages/cli/bin/hyperframes.mjs render \
  /data/project --output /data/render.mp4 --workers 1 --quality draft
# → 130 KB · 10,0 s de vídeo · 7,7 s de render (software GPU)
```

Necesita **espacio en `/tmp`**: con los 512 Mi iniciales el CLI aborta con
«Low disk space» antes de capturar. El manifiesto monta un emptyDir de 4 Gi en
`/tmp` y 1 Gi en `/dev/shm`. El MP4 se escribe en `/data` (emptyDir de 2 Gi).

## Qué NO soporta este contenedor

- **Autenticación**: el studio no tiene auth propia y su API permite leer y
  escribir los ficheros del proyecto. Este despliegue es **solo dev** y el pod
  va endurecido (no-root, rootfs read-only, sin token de SA, seccomp,
  `drop ALL`, `emptyDir` acotados). Antes de pre/pro hace falta SSO/proxy
  (oauth2-proxy, Keycloak o forward-auth de Traefik) y una NetworkPolicy.
- **Persistencia**: `/data` es `emptyDir`; las ediciones y el historial se
  pierden al recrear el pod. Para uso real, PVC para `/data/project` y
  `~/.local/state/hyperframes`.
- **Varias réplicas / HPA**: el preview mantiene estado en disco. Una réplica.
- **Render distribuido** (Lambda/Cloud Run), app de escritorio y publish:
  fuera de alcance.
- **Fuentes CJK/extra**: se instala el set base (Liberation, DejaVu, Noto
  emoji/core). Un proyecto que necesite CJK requiere ampliar la imagen.
- **`--background` / ciclo de vida**: en el pod se usa `--foreground`; no
  aplican `preview --stop/--list`.

## Verificación

```bash
# Local (sin k8s)
docker build -t ita-hyperframes:dev .
docker run --rm -p 3002:3002 ita-hyperframes:dev
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3002/   # 200
docker run --rm ita-hyperframes:dev ffprobe -version | head -n1
docker run --rm ita-hyperframes:dev /opt/chrome/chrome-headless-shell --version

# vía manifest (envsubst)
NS=dev HYPERFRAMES_IMAGE=registry.itadaptativa.es/ita-hyperframes:dev-<sha> \
HYPERFRAMES_HOST=hyperframes.dev.itadaptativa.es TLS_ISSUER=letsencrypt-prod-dns \
  envsubst '${NS} ${HYPERFRAMES_IMAGE} ${HYPERFRAMES_HOST} ${TLS_ISSUER}' \
  < k8s/hyperframes.yaml | kubectl apply --dry-run=client -f -
```

En el CI, `deploy.yml` comprueba antes del apply el endpoint de `KUBE_CONFIG`
contra `KUBE_SERVER` (L-116) y el hueco de `limits.cpu` en la cuota (L-079),
y después espera el rollout (600 s) y un `GET /` 200 con TLS válido.

Rollback: repite el deploy de un sha anterior con el workflow
(`workflow_dispatch`) o `kubectl -n dev rollout undo deployment/hyperframes`.
