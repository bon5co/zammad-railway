#!/usr/bin/env bash
# Railway entrypoint for Zammad 7.1.2 — one container, four roles.
#
#   1. Wait for Postgres, then run upstream's own init (db:create/migrate/seed
#      on a fresh database, db:migrate + locale sync on an existing one).
#   2. Seed the administrator and mark the setup wizard done BEFORE anything
#      binds a port. Seeding after start is not sufficient: the public URL is
#      live the moment nginx accepts, and `POST /api/v1/users` is the takeover.
#   3. Start rails (127.0.0.1:3000), the websocket server (127.0.0.1:6042) and
#      the background worker, then nginx on Railway's injected $PORT in the
#      foreground. Railway's HTTP healthcheck dials the INJECTED port, not the
#      domain's target port, so nginx must honour $PORT.
#   4. If any role dies, kill the container so Railway restarts it — a
#      half-running help desk that still answers the healthcheck is worse than
#      a restart.
set -euo pipefail

cd /opt/zammad

log() { echo "[railway] $*"; }

: "${PORT:=8080}"
: "${ZAMMAD_RAILS_PORT:=3000}"
: "${ZAMMAD_WEBSOCKET_PORT:=6042}"
: "${ZAMMAD_ADMIN_EMAIL:=admin@example.com}"

if [ -z "${ZAMMAD_ADMIN_PASSWORD:-}" ]; then
    log "FATAL: ZAMMAD_ADMIN_PASSWORD is empty. Refusing to boot: an instance"
    log "       with no seeded admin can be claimed by anyone who opens the URL."
    exit 1
fi

# Rails' cache store. Upstream's compose file points this at a separate
# memcached container; in one container the file store is equivalent and one
# service cheaper. Left overridable for anyone who does run memcached.
if [ -n "${MEMCACHE_SERVERS:-}" ]; then
    log "using memcached at ${MEMCACHE_SERVERS}"
fi

log "waiting for postgres at ${POSTGRESQL_HOST}:${POSTGRESQL_PORT}"
CLEAN_HOST=${POSTGRESQL_HOST#[}; CLEAN_HOST=${CLEAN_HOST%]}
until pg_isready -q -h "$CLEAN_HOST" -p "$POSTGRESQL_PORT"; do sleep 1; done

log "running database init (first boot migrates and seeds; this takes minutes)"
/opt/zammad/bin/docker-entrypoint zammad-init

log "seeding administrator"
bundle exec rails r /opt/zammad/railway-seed-admin.rb

# --- role processes -------------------------------------------------------
PIDS=()
start() {
    local name="$1"; shift
    log "starting ${name}"
    "$@" &
    PIDS+=("$!")
}

shutdown() {
    log "shutting down"
    for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
    exit 0
}
trap shutdown TERM INT

start railsserver bundle exec puma -b "tcp://127.0.0.1:${ZAMMAD_RAILS_PORT}" -e "${RAILS_ENV}"
start websocket bundle exec script/websocket-server.rb -b 127.0.0.1 -p "${ZAMMAD_WEBSOCKET_PORT}" start
start worker bundle exec script/background-worker.rb start

log "waiting for railsserver to accept on 127.0.0.1:${ZAMMAD_RAILS_PORT}"
for _ in $(seq 1 180); do
    (echo > /dev/tcp/127.0.0.1/"${ZAMMAD_RAILS_PORT}") >/dev/null 2>&1 && break
    sleep 1
done

# --- nginx ----------------------------------------------------------------
# Same rewrite upstream's zammad-nginx role does, with the resolver line kept
# because Railway's private network is IPv6 and the stock config has no
# resolver at all.
NAMESERVER=$(grep "^nameserver" --max-count 1 < /etc/resolv.conf | awk '{print $2}')
case "$NAMESERVER" in
    *:*) [ "${NAMESERVER#\[}" = "$NAMESERVER" ] && NAMESERVER="[$NAMESERVER]" ;;
esac
echo "resolver $NAMESERVER valid=5s;" > /etc/nginx/conf.d/resolver.conf

sed -e "s#\(listen\)\(.*\)80#\1\2${PORT}#g" \
    -e "s#proxy_set_header X-Forwarded-Proto .*;#proxy_set_header X-Forwarded-Proto ${NGINX_SERVER_SCHEME};#g" \
    -e "s#proxy_pass http://zammad-railsserver;#proxy_pass http://127.0.0.1:${ZAMMAD_RAILS_PORT};#g" \
    -e "s#proxy_pass http://zammad-websocket;#proxy_pass http://127.0.0.1:${ZAMMAD_WEBSOCKET_PORT};#g" \
    -e "s#server_name .*#server_name ${NGINX_SERVER_NAME};#g" \
    -e "s#client_max_body_size .*#client_max_body_size ${NGINX_CLIENT_MAX_BODY_SIZE};#g" \
    -e 's#/var/log/nginx/zammad.\(access\|error\).log#/dev/stdout#g' \
    < contrib/nginx/zammad.conf > /etc/nginx/sites-enabled/default

log "starting nginx on ${PORT}"
nginx -g 'daemon off;' &
PIDS+=("$!")

# First role to exit takes the container down with it.
wait -n
log "a role exited; stopping container"
shutdown
