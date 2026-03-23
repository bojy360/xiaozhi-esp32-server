#!/usr/bin/env bash
set -euo pipefail

# 本脚本用于：
# 1) build 模式：基于本地源码构建镜像并部署
# 2) dev 模式：开发快速迭代（默认仅重启 server，不重建大镜像）
# 3) 兼容 macOS / Ubuntu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
STACK_DIR="$REPO_ROOT/main/xiaozhi-server"

COMPOSE_BASE="$STACK_DIR/docker-compose_all.yml"
COMPOSE_BUILD_OVERRIDE="$STACK_DIR/.docker-compose.local-build.yml"
COMPOSE_DEV_OVERRIDE="$STACK_DIR/.docker-compose.local-dev.yml"

SERVER_IMAGE="xiaozhi-esp32-server:server_local"
WEB_IMAGE="xiaozhi-esp32-server:web_local"

MODEL_PATH="$STACK_DIR/models/SenseVoiceSmall/model.pt"
MODEL_URL="https://modelscope.cn/models/iic/SenseVoiceSmall/resolve/master/model.pt"

# 国内镜像配置（默认启用）
USE_CN_MIRROR=1
SERVER_BASE_IMAGE_CN="ghcr.nju.edu.cn/xinnan-tech/xiaozhi-esp32-server:server-base"
SERVER_DOCKERFILE_BUILD="$REPO_ROOT/Dockerfile-server"
TEMP_SERVER_DOCKERFILE="$REPO_ROOT/.Dockerfile-server.cn-mirror.tmp"

# mode: build|dev
MODE="build"
# target: server|all（build 默认 all，dev 默认 server）
TARGET=""

SKIP_BUILD=0
SKIP_MODEL_DOWNLOAD=0
NO_CACHE=0
ONLY_BUILD=0
ONLY_UP=0
DO_DOWN=0
REBUILD=0

usage() {
  cat <<'EOF'
用法:
  ./docker-deploy-local.sh [选项]

模式:
  --mode build|dev
    - build: 本地构建镜像 + 部署
    - dev: 开发快迭代（默认只处理 server，支持代码改完后快速重启）

目标:
  --target server|all
    - build 模式默认 all
    - dev 模式默认 server

常用:
  ./docker-deploy-local.sh --mode dev
  ./docker-deploy-local.sh --mode dev --target server
  ./docker-deploy-local.sh --mode build --down

选项:
  --mode <build|dev>      运行模式（默认 build）
  --target <server|all>   作用范围（默认: build=all, dev=server）
  --skip-build            跳过镜像构建，只执行 up
  --rebuild               强制重建镜像（dev 模式下默认不重建）
  --skip-model-download   若 model.pt 不存在也不下载
  --no-cache              构建镜像时加 --no-cache
  --only-build            只构建镜像，不启动容器
  --only-up               只启动容器（等同于 --skip-build）
  --down                  先执行 compose down 再 up
  --no-cn-mirror          关闭国内镜像替换（server 使用原始 Dockerfile FROM）
  -h, --help              查看帮助
EOF
}

log() { printf "\033[1;36m[local-deploy]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[warn]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[error]\033[0m %s\n" "$*"; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
    return 0
  fi
  if has_cmd docker-compose; then
    echo "docker-compose"
    return 0
  fi
  return 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        shift
        MODE="${1:-}"
        ;;
      --target)
        shift
        TARGET="${1:-}"
        ;;
      --skip-build) SKIP_BUILD=1 ;;
      --rebuild) REBUILD=1 ;;
      --skip-model-download) SKIP_MODEL_DOWNLOAD=1 ;;
      --no-cache) NO_CACHE=1 ;;
      --only-build) ONLY_BUILD=1 ;;
      --only-up) ONLY_UP=1; SKIP_BUILD=1 ;;
      --down) DO_DOWN=1 ;;
      --no-cn-mirror) USE_CN_MIRROR=0 ;;
      -h|--help) usage; exit 0 ;;
      *)
        err "未知参数: $1"
        usage
        exit 1
        ;;
    esac
    shift
  done

  case "$MODE" in
    build|dev) ;;
    *) err "--mode 仅支持 build|dev（当前: $MODE）"; exit 1 ;;
  esac

  if [[ -z "$TARGET" ]]; then
    if [[ "$MODE" == "dev" ]]; then
      TARGET="server"
    else
      TARGET="all"
    fi
  fi

  case "$TARGET" in
    server|all) ;;
    *) err "--target 仅支持 server|all（当前: $TARGET）"; exit 1 ;;
  esac

  if [[ $ONLY_BUILD -eq 1 && $ONLY_UP -eq 1 ]]; then
    err "--only-build 和 --only-up 不能同时使用"
    exit 1
  fi
}

check_env() {
  local os
  os="$(uname -s)"
  case "$os" in
    Darwin|Linux) ;;
    *) err "当前系统不支持: $os（仅支持 macOS / Linux）"; exit 1 ;;
  esac

  if ! has_cmd docker; then
    err "未找到 docker，请先安装 Docker Desktop(macOS) 或 Docker Engine(Ubuntu)"
    exit 1
  fi

  if ! docker info >/dev/null 2>&1; then
    err "Docker daemon 未就绪。macOS 请先打开 Docker Desktop；Ubuntu 请先启动 docker 服务。"
    exit 1
  fi

  if [[ ! -f "$COMPOSE_BASE" ]]; then
    err "未找到 compose 文件: $COMPOSE_BASE"
    exit 1
  fi

  if ! COMPOSE_BIN="$(compose_cmd)"; then
    err "未找到 docker compose（需要 docker compose 或 docker-compose）"
    exit 1
  fi
}

prepare_dirs_and_files() {
  mkdir -p "$STACK_DIR/data" \
           "$STACK_DIR/models/SenseVoiceSmall" \
           "$STACK_DIR/mysql/data" \
           "$STACK_DIR/uploadfile"

  if [[ ! -f "$STACK_DIR/data/.config.yaml" ]]; then
    if [[ -f "$STACK_DIR/config_from_api.yaml" ]]; then
      cp "$STACK_DIR/config_from_api.yaml" "$STACK_DIR/data/.config.yaml"
      log "已初始化配置文件: $STACK_DIR/data/.config.yaml"
    else
      warn "未找到 config_from_api.yaml，请手动创建 $STACK_DIR/data/.config.yaml"
    fi
  fi

  if [[ ! -f "$MODEL_PATH" ]]; then
    if [[ $SKIP_MODEL_DOWNLOAD -eq 1 ]]; then
      warn "model.pt 不存在，且已指定 --skip-model-download，后续 server 可能启动失败"
    else
      if has_cmd curl; then
        log "未检测到模型文件，开始下载 SenseVoiceSmall model.pt（首次可能较慢）"
        curl -fL "$MODEL_URL" -o "$MODEL_PATH"
      else
        warn "未找到 curl，无法自动下载 model.pt，请手动下载到: $MODEL_PATH"
      fi
    fi
  fi
}

prepare_server_dockerfile() {
  SERVER_DOCKERFILE_BUILD="$REPO_ROOT/Dockerfile-server"

  if [[ $USE_CN_MIRROR -eq 0 ]]; then
    log "server 构建使用默认基础镜像（未启用国内镜像替换）"
    return
  fi

  if ! awk -v new_from="FROM ${SERVER_BASE_IMAGE_CN}" '
    BEGIN { replaced=0 }
    !replaced && $1=="FROM" { print new_from; replaced=1; next }
    { print }
  ' "$REPO_ROOT/Dockerfile-server" > "$TEMP_SERVER_DOCKERFILE"; then
    warn "生成临时 Dockerfile 失败，回退使用原始 Dockerfile-server"
    SERVER_DOCKERFILE_BUILD="$REPO_ROOT/Dockerfile-server"
    return
  fi

  SERVER_DOCKERFILE_BUILD="$TEMP_SERVER_DOCKERFILE"
  log "server 构建基础镜像已切换到国内源: $SERVER_BASE_IMAGE_CN"
}

cleanup_temp_files() {
  rm -f "$TEMP_SERVER_DOCKERFILE" || true
}

image_exists() {
  docker image inspect "$1" >/dev/null 2>&1
}

build_server_image() {
  prepare_server_dockerfile
  log "构建 server 镜像（本地代码）: $SERVER_IMAGE"
  log "使用 Dockerfile: $SERVER_DOCKERFILE_BUILD"
  if [[ $NO_CACHE -eq 1 ]]; then
    docker build --no-cache --pull=false -t "$SERVER_IMAGE" -f "$SERVER_DOCKERFILE_BUILD" "$REPO_ROOT"
  else
    docker build --pull=false -t "$SERVER_IMAGE" -f "$SERVER_DOCKERFILE_BUILD" "$REPO_ROOT"
  fi
}

build_web_image() {
  log "构建 web 镜像（本地代码）: $WEB_IMAGE"
  if [[ $NO_CACHE -eq 1 ]]; then
    docker build --no-cache -t "$WEB_IMAGE" -f "$REPO_ROOT/Dockerfile-web" "$REPO_ROOT"
  else
    docker build -t "$WEB_IMAGE" -f "$REPO_ROOT/Dockerfile-web" "$REPO_ROOT"
  fi
}

build_images() {
  if [[ $SKIP_BUILD -eq 1 ]]; then
    log "跳过镜像构建"
    return
  fi

  if [[ "$MODE" == "build" ]]; then
    if [[ "$TARGET" == "all" ]]; then
      build_server_image
      build_web_image
    else
      build_server_image
    fi
    return
  fi

  # dev 模式：默认不重建，只有 --rebuild 或镜像不存在才构建
  if [[ $REBUILD -eq 1 ]] || ! image_exists "$SERVER_IMAGE"; then
    if ! image_exists "$SERVER_IMAGE"; then
      warn "dev 模式下未找到本地 server 镜像，自动构建一次"
    else
      log "dev 模式收到 --rebuild，重建 server 镜像"
    fi
    build_server_image
  else
    log "dev 模式复用已有 server 镜像: $SERVER_IMAGE"
  fi

  if [[ "$TARGET" == "all" ]]; then
    if [[ $REBUILD -eq 1 ]] || ! image_exists "$WEB_IMAGE"; then
      if ! image_exists "$WEB_IMAGE"; then
        warn "dev 模式下未找到本地 web 镜像，自动构建一次"
      else
        log "dev 模式收到 --rebuild，重建 web 镜像"
      fi
      build_web_image
    else
      log "dev 模式复用已有 web 镜像: $WEB_IMAGE"
    fi
  fi
}

write_build_override_compose() {
  cat > "$COMPOSE_BUILD_OVERRIDE" <<EOF
services:
  xiaozhi-esp32-server:
    image: $SERVER_IMAGE
    pull_policy: never

  xiaozhi-esp32-server-web:
    image: $WEB_IMAGE
    pull_policy: never
EOF
}

write_dev_override_compose() {
  cat > "$COMPOSE_DEV_OVERRIDE" <<EOF
services:
  xiaozhi-esp32-server:
    image: $SERVER_IMAGE
    pull_policy: never
    command: ["python", "app.py"]
    volumes:
      - $STACK_DIR/data:/opt/xiaozhi-esp32-server/data
      - $STACK_DIR/models/SenseVoiceSmall/model.pt:/opt/xiaozhi-esp32-server/models/SenseVoiceSmall/model.pt
      - $REPO_ROOT/main/xiaozhi-server:/opt/xiaozhi-esp32-server

  xiaozhi-esp32-server-web:
    image: $WEB_IMAGE
    pull_policy: never
EOF
}

deploy_stack() {
  if [[ $ONLY_BUILD -eq 1 ]]; then
    log "仅构建模式，已完成。"
    return
  fi

  write_build_override_compose

  local compose_args=( -f "$COMPOSE_BASE" -f "$COMPOSE_BUILD_OVERRIDE" )
  if [[ "$MODE" == "dev" ]]; then
    write_dev_override_compose
    compose_args+=( -f "$COMPOSE_DEV_OVERRIDE" )
  fi

  if [[ $DO_DOWN -eq 1 ]]; then
    log "执行 down 清理旧容器..."
    (cd "$STACK_DIR" && $COMPOSE_BIN "${compose_args[@]}" down)
  fi

  if [[ "$MODE" == "dev" && "$TARGET" == "server" ]]; then
    log "dev 模式：仅更新 server 容器（不影响 db/redis/web）..."
    (cd "$STACK_DIR" && $COMPOSE_BIN "${compose_args[@]}" up -d --no-deps xiaozhi-esp32-server)
  else
    log "启动容器..."
    (cd "$STACK_DIR" && $COMPOSE_BIN "${compose_args[@]}" up -d --remove-orphans)
  fi

  log "部署完成（mode=${MODE:-build}, target=${TARGET:-server}）"
  echo
  echo "管理后台:  http://127.0.0.1:8002"
  echo "WS 地址:    ws://127.0.0.1:8000/xiaozhi/v1/"
  echo "OTA 地址:   http://127.0.0.1:8002/xiaozhi/ota/"
  echo
  echo "查看日志:"
  echo "  docker logs -f xiaozhi-esp32-server-web"
  echo "  docker logs -f xiaozhi-esp32-server"
  echo
  if [[ "$MODE" == "dev" ]]; then
    echo "dev 模式提示：改完 Python 代码后执行以下命令即可快速生效（无需重建镜像）："
    echo "  docker restart xiaozhi-esp32-server"
    echo
  fi
  echo "若首次部署，请在智控台参数管理里确认 server.secret，并同步到:"
  echo "  $STACK_DIR/data/.config.yaml"
}

main() {
  trap cleanup_temp_files EXIT
  parse_args "$@"
  check_env
  prepare_dirs_and_files
  build_images
  deploy_stack
}

main "$@"
