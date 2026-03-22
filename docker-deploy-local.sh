#!/usr/bin/env bash
set -euo pipefail

# 本脚本用于：
# 1) 使用本地源码构建 server/web 镜像
# 2) 使用 docker compose 启动全模块（server + web + mysql + redis）
# 3) 兼容 macOS / Ubuntu（不依赖 apt/systemctl/whiptail）

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
STACK_DIR="$REPO_ROOT/main/xiaozhi-server"
COMPOSE_BASE="$STACK_DIR/docker-compose_all.yml"
COMPOSE_OVERRIDE="$STACK_DIR/.docker-compose.local-build.yml"

SERVER_IMAGE="xiaozhi-esp32-server:server_local"
WEB_IMAGE="xiaozhi-esp32-server:web_local"
MODEL_PATH="$STACK_DIR/models/SenseVoiceSmall/model.pt"
MODEL_URL="https://modelscope.cn/models/iic/SenseVoiceSmall/resolve/master/model.pt"

# 国内镜像配置（默认启用）
USE_CN_MIRROR=1
SERVER_BASE_IMAGE_CN="ghcr.nju.edu.cn/xinnan-tech/xiaozhi-esp32-server:server-base"
SERVER_DOCKERFILE_BUILD="$REPO_ROOT/Dockerfile-server"

SKIP_BUILD=0
SKIP_MODEL_DOWNLOAD=0
NO_CACHE=0
ONLY_BUILD=0
ONLY_UP=0
DO_DOWN=0

usage() {
  cat <<'EOF'
用法:
  ./docker-deploy-local.sh [选项]

说明:
  - 基于当前本地代码构建 Docker 镜像（不是拉远程 server/web 镜像）
  - 适用于 macOS / Ubuntu

选项:
  --skip-build            跳过镜像构建，只执行 compose up
  --skip-model-download   若 model.pt 不存在也不下载
  --no-cache              构建镜像时加 --no-cache
  --only-build            只构建镜像，不启动容器
  --only-up               只启动容器（等同于 --skip-build）
  --down                  先执行 compose down 再 up
  --no-cn-mirror          关闭国内镜像替换（server 使用原始 Dockerfile FROM）
  -h, --help              查看帮助

示例:
  ./docker-deploy-local.sh
  ./docker-deploy-local.sh --no-cache --down
  ./docker-deploy-local.sh --only-build
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
      --skip-build) SKIP_BUILD=1 ;;
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
    *)
      err "当前系统不支持: $os（仅支持 macOS / Linux）"
      exit 1
      ;;
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

  local tmp_dockerfile="$REPO_ROOT/.Dockerfile-server.cn-mirror.tmp"
  # 仅替换第一行 FROM，避免改动原文件
  if ! awk -v new_from="FROM ${SERVER_BASE_IMAGE_CN}" '
    NR==1 && $1=="FROM" { print new_from; next }
    { print }
  ' "$REPO_ROOT/Dockerfile-server" > "$tmp_dockerfile"; then
    warn "生成临时 Dockerfile 失败，回退使用原始 Dockerfile-server"
    SERVER_DOCKERFILE_BUILD="$REPO_ROOT/Dockerfile-server"
    return
  fi

  SERVER_DOCKERFILE_BUILD="$tmp_dockerfile"
  log "server 构建基础镜像已切换到国内源: $SERVER_BASE_IMAGE_CN"
}

build_images() {
  if [[ $SKIP_BUILD -eq 1 ]]; then
    log "跳过镜像构建"
    return
  fi

  prepare_server_dockerfile

  log "构建 server 镜像（本地代码）: $SERVER_IMAGE"
  if [[ $NO_CACHE -eq 1 ]]; then
    docker build --no-cache -t "$SERVER_IMAGE" -f "$SERVER_DOCKERFILE_BUILD" "$REPO_ROOT"
  else
    docker build -t "$SERVER_IMAGE" -f "$SERVER_DOCKERFILE_BUILD" "$REPO_ROOT"
  fi

  log "构建 web 镜像（本地代码）: $WEB_IMAGE"
  if [[ $NO_CACHE -eq 1 ]]; then
    docker build --no-cache -t "$WEB_IMAGE" -f "$REPO_ROOT/Dockerfile-web" "$REPO_ROOT"
  else
    docker build -t "$WEB_IMAGE" -f "$REPO_ROOT/Dockerfile-web" "$REPO_ROOT"
  fi

  # 清理临时 Dockerfile
  if [[ "$SERVER_DOCKERFILE_BUILD" == "$REPO_ROOT/.Dockerfile-server.cn-mirror.tmp" ]]; then
    rm -f "$SERVER_DOCKERFILE_BUILD" || true
    SERVER_DOCKERFILE_BUILD="$REPO_ROOT/Dockerfile-server"
  fi
}

write_override_compose() {
  cat > "$COMPOSE_OVERRIDE" <<EOF
services:
  xiaozhi-esp32-server:
    image: $SERVER_IMAGE
    pull_policy: never

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

  write_override_compose

  if [[ $DO_DOWN -eq 1 ]]; then
    log "执行 down 清理旧容器..."
    (cd "$STACK_DIR" && $COMPOSE_BIN -f "$COMPOSE_BASE" -f "$COMPOSE_OVERRIDE" down)
  fi

  log "启动容器（使用本地构建镜像）..."
  (cd "$STACK_DIR" && $COMPOSE_BIN -f "$COMPOSE_BASE" -f "$COMPOSE_OVERRIDE" up -d --remove-orphans)

  log "部署完成。"
  echo
  echo "管理后台:  http://127.0.0.1:8002"
  echo "WS 地址:    ws://127.0.0.1:8000/xiaozhi/v1/"
  echo "OTA 地址:   http://127.0.0.1:8002/xiaozhi/ota/"
  echo
  echo "查看日志:"
  echo "  docker logs -f xiaozhi-esp32-server-web"
  echo "  docker logs -f xiaozhi-esp32-server"
  echo
  echo "若首次部署，请在智控台参数管理里确认 server.secret，并同步到:"
  echo "  $STACK_DIR/data/.config.yaml"
}

main() {
  parse_args "$@"
  check_env
  prepare_dirs_and_files
  build_images
  deploy_stack
}

main "$@"
