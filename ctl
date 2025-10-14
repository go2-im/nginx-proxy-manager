#!/usr/bin/env bash
set -euo pipefail

# --- config ---
APP_NAME="app"                              # compose 服务名
RENDER_DIR=".rendered"                      # 渲染输出目录
LISTEN_TPL="backend-templates/_listen.conf.tpl"
LISTEN_OUT="${RENDER_DIR}/_listen.conf"
DEFAULT_TPL="rootfs/etc/nginx/conf.d/default.conf.tpl"
DEFAULT_OUT="${RENDER_DIR}/default.conf"
PROXY_CONF_TPL="rootfs/etc/nginx/conf.d/include/proxy.conf.tpl"
PROXY_CONF_OUT="${RENDER_DIR}/proxy.conf"
PROXY_HOST_TPL="backend-templates/proxy_host.conf.tpl"
PROXY_HOST_OUT="${RENDER_DIR}/proxy_host.conf"

cd "$(dirname "$0")"

color() { printf "\033[%sm%s\033[0m\n" "$1" "$2"; }
info()  { color "36" "==> $*"; }
ok()    { color "32" "✅ $*"; }
warn()  { color "33" "⚠️  $*"; }
err()   { color "31" "❌ $*"; }

require() { command -v "$1" >/dev/null 2>&1 || { err "缺少命令：$1"; exit 1; }; }

load_env() {
  if [[ -f .env ]]; then
    # shellcheck disable=SC2046
    export $(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' .env | sed 's/[[:space:]]*#.*$//' | xargs)
  fi
  : "${HTTP_PORT:=80}"
  : "${HTTPS_PORT:=443}"
  : "${ADMIN_PORT:=81}"
  : "${DB_MYSQL_HOST:=db}"
  : "${DB_MYSQL_PORT:=3306}"
  : "${DB_MYSQL_USER:=npm}"
  : "${DB_MYSQL_PASSWORD:=npm}"
  : "${DB_MYSQL_NAME:=npm}"
  : "${TZ:=UTC}"
}

render() {
  load_env
  mkdir -p "${RENDER_DIR}"
  require envsubst

  [[ -f "${LISTEN_TPL}"  ]] || { err "缺少模板：${LISTEN_TPL}";  exit 1; }
  [[ -f "${DEFAULT_TPL}" ]] || { err "缺少模板：${DEFAULT_TPL}"; exit 1; }
  [[ -f "${PROXY_CONF_TPL}" ]] || { err "缺少模板：${PROXY_CONF_TPL}"; exit 1; }
  [[ -f "${PROXY_HOST_TPL}" ]] || { err "缺少模板：${PROXY_HOST_TPL}"; exit 1; }

  info "渲染 ${LISTEN_TPL} -> ${LISTEN_OUT}"
  envsubst '${HTTP_PORT} ${HTTPS_PORT}' < "${LISTEN_TPL}"  > "${LISTEN_OUT}"


  info "渲染 ${DEFAULT_TPL} -> ${DEFAULT_OUT}"
  envsubst '${HTTP_PORT} ${HTTPS_PORT}' < "${DEFAULT_TPL}" > "${DEFAULT_OUT}"

  info "渲染 ${PROXY_CONF_TPL} -> ${PROXY_CONF_OUT}"
  envsubst '${HTTP_PORT} ${HTTPS_PORT}' < "${PROXY_CONF_TPL}" > "${PROXY_CONF_OUT}"

  info "渲染 ${PROXY_HOST_TPL} -> ${PROXY_HOST_OUT}"
  envsubst '${HTTP_PORT} ${HTTPS_PORT}' < "${PROXY_HOST_TPL}" > "${PROXY_HOST_OUT}"

  ok "渲染完成：HTTP=${HTTP_PORT}, HTTPS=${HTTPS_PORT}"
}

compose_pull()   { docker compose pull "${APP_NAME}"; }
compose_up()     { docker compose up -d; }
compose_down()   { docker compose down; }
compose_logs()   { docker compose logs -f "${APP_NAME}"; }
compose_status() { docker compose ps; }
app_id()         { docker compose ps -q "${APP_NAME}"; }

check_in_container() {
  load_env
  local cid
  cid="$(app_id)"
  [[ -n "${cid}" ]] || { err "容器未运行"; return 1; }

  info "校验容器内文件与端口..."
  docker exec "${cid}" bash -lc "grep -q 'listen ${HTTP_PORT};' /app/templates/_listen.conf" \
    && ok "_listen.conf 包含 listen ${HTTP_PORT}" \
    || { err "_listen.conf 未包含 listen ${HTTP_PORT}"; return 1; }

  docker exec "${cid}" bash -lc "grep -q 'listen ${HTTP_PORT}[; ]' /etc/nginx/conf.d/default.conf" \
    && ok "default.conf 包含 HTTP ${HTTP_PORT}" \
    || { err "default.conf 未包含 HTTP ${HTTP_PORT}"; return 1; }

  docker exec "${cid}" bash -lc "grep -q 'listen ${HTTPS_PORT} ssl' /etc/nginx/conf.d/default.conf" \
    && ok "default.conf 包含 HTTPS ${HTTPS_PORT}" \
    || { err "default.conf 未包含 HTTPS ${HTTPS_PORT}"; return 1; }

  info "nginx 配置测试"
  docker exec "${cid}" nginx -t >/dev/null && ok "nginx -t 通过"
}

usage() {
  cat <<'USAGE'
用法：./ctl <命令>

命令：
  env         显示当前环境变量并预览渲染（不落盘、不重启）
  render      渲染模板到 .rendered/（根据 .env）
  update      渲染 -> pull upstream -> up -d -> 健检查
  check       健检查（校验容器内端口与 nginx 配置）
  restart     重启容器（不 pull）
  logs        跟随日志
  status      查看容器状态
  down        停止并移除
  rollback    快速回滚到上一个镜像版本

示例：
  ./ctl env
  ./ctl render
  ./ctl update
  ./ctl check
  ./ctl rollback
USAGE
}

show_env_and_preview() {
  load_env
  echo "—— 当前环境变量 ——"
  printf "HTTP_PORT=%s\nHTTPS_PORT=%s\nADMIN_PORT=%s\n" "$HTTP_PORT" "$HTTPS_PORT" "$ADMIN_PORT"
  printf "DB_MYSQL_HOST=%s\nDB_MYSQL_PORT=%s\nDB_MYSQL_USER=%s\nDB_MYSQL_PASSWORD=%s\nDB_MYSQL_NAME=%s\n" \
    "$DB_MYSQL_HOST" "$DB_MYSQL_PORT" "$DB_MYSQL_USER" "$DB_MYSQL_PASSWORD" "$DB_MYSQL_NAME"
  printf "TZ=%s\n" "$TZ"

  echo
  echo "—— 渲染预览：_listen.conf ——"
  HTTP_PORT="${HTTP_PORT}" HTTPS_PORT="${HTTPS_PORT}" envsubst < "${LISTEN_TPL}" | sed -n '1,80p'

  echo
  echo "—— 渲染预览：default.conf ——"
  HTTP_PORT="${HTTP_PORT}" HTTPS_PORT="${HTTPS_PORT}" envsubst < "${DEFAULT_TPL}" | sed -n '1,80p'
}

rollback() {
  info "尝试回滚到上一版本镜像..."
  local curr prev cid
  cid="$(app_id || true)"
  if [[ -z "${cid}" ]]; then
    warn "容器未运行，将直接寻找历史镜像。"
  else
    curr="$(docker inspect --format='{{.Image}}' "${cid}")" || true
  fi

  prev="$(docker image ls --format '{{.ID}} {{.Repository}}:{{.Tag}}' \
    | grep 'jc21/nginx-proxy-manager' \
    | awk '{print $1}' \
    | grep -v "${curr:-}" \
    | head -n 1 || true)"

  [[ -n "${prev}" ]] || { err "未找到可回滚的旧镜像"; exit 1; }

  warn "将使用旧镜像 ID: ${prev}"
  compose_down
  docker run --rm "${prev}" /bin/true || true
  compose_up
  sleep 2
  check_in_container || { err "回滚后校验失败"; exit 1; }
  ok "回滚完成"
}

update() {
  render
  info "拉取上游 latest"
  compose_pull
  info "启动/重建服务"
  compose_up
  sleep 2
  check_in_container
  info "最近 50 行日志："
  docker compose logs --tail=50 "${APP_NAME}" || true
  ok "更新完成"
}

restart() {
  render
  info "重启服务（不拉取镜像）"
  compose_up
  sleep 2
  check_in_container
  ok "已重启"
}

main() {
  local cmd="${1:-}"
  case "${cmd}" in
    env)       show_env_and_preview ;;
    render)    render ;;
    update)    update ;;
    check)     check_in_container ;;
    restart)   restart ;;
    logs)      compose_logs ;;
    status)    compose_status ;;
    down)      compose_down ;;
    rollback)  rollback ;;
    ""|-h|--help|help) usage ;;
    *) err "未知命令：${cmd}"; usage; exit 1 ;;
  esac
}

main "$@"