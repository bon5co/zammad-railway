# Zammad 7.1.2 wrapper for Railway.
#
# Two things this image changes about a stock Zammad deploy:
#
#   1. The admin account is seeded from the environment during database init,
#      before any process binds a port. Stock Zammad serves
#      `POST /api/v1/users` unauthenticated on a fresh instance
#      (UsersController#create -> create_admin -> Service::User::AddFirstAdmin),
#      so the first stranger to reach the URL becomes Admin+Agent. The
#      marketplace listings tell the deployer to go and finish the setup
#      wizard after the deploy, which is exactly the window that call lives in.
#
#   2. All four Zammad roles (rails, websocket, background worker, nginx) run
#      in ONE container. Railway bills per service, none of the roles need a
#      shared volume (attachments live in Postgres), and Rails' file cache
#      store works in-container, so a stock seven-service stack becomes three:
#      this container plus Postgres plus Redis.
#
# Everything the deploy form should not ask for is baked here as ENV: a literal
# defaultValue is dropped by templateGenerate and would publish as a blank
# required field.
FROM ghcr.io/zammad/zammad:7.1.2@sha256:a2c6b958f3390fb9abb6aa8912af54dab7a4caa86aff6def158fc56b2a4a2dd5

ENV ELASTICSEARCH_ENABLED=false \
    POSTGRESQL_DB=zammad_production \
    POSTGRESQL_USER=zammad \
    POSTGRESQL_PORT=5432 \
    POSTGRESQL_OPTIONS="?pool=50" \
    POSTGRESQL_DB_CREATE=true \
    ZAMMAD_RAILSSERVER_HOST=127.0.0.1 \
    ZAMMAD_RAILSSERVER_PORT=3000 \
    ZAMMAD_WEBSOCKET_HOST=127.0.0.1 \
    ZAMMAD_WEBSOCKET_PORT=6042 \
    ZAMMAD_BIND_IP=127.0.0.1 \
    NGINX_SERVER_NAME=_ \
    NGINX_SERVER_SCHEME=https \
    NGINX_CLIENT_MAX_BODY_SIZE=50M \
    ZAMMAD_ADMIN_EMAIL=admin@example.com \
    ZAMMAD_ADMIN_FIRSTNAME=Admin \
    ZAMMAD_ADMIN_LASTNAME=User \
    ZAMMAD_ORGANIZATION="My Company" \
    TZ=Etc/UTC

COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
COPY seed-admin.rb /opt/zammad/railway-seed-admin.rb

USER root
RUN chmod +x /usr/local/bin/railway-entrypoint.sh
USER zammad

WORKDIR /opt/zammad

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
