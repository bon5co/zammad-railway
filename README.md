# zammad-railway

Railway-tuned [Zammad](https://zammad.org) 7.1.2 image, published as
`ghcr.io/bon5co/zammad-railway:7.1.2`.

Two things it changes about a stock Zammad deploy.

## 1. The admin account is seeded before anything binds a port

On a fresh Zammad instance `POST /api/v1/users` is served **unauthenticated**:
`UsersController#create` falls through to `create_admin`, which calls
`Service::User::AddFirstAdmin`, and that service only refuses once
`Service::System::CheckSetup.done?` is true — i.e. once an admin exists. So on
a stock deploy the first stranger to reach the public URL owns the help desk.

Reproduced against `ghcr.io/zammad/zammad:7.1.2` with the marketplace
configuration (Postgres + Redis, Elasticsearch disabled), from outside the
container:

```
GET  /api/v1/getting_started          -> 200 {"setup_done":false,...}   (csrf-token in the response header)
POST /api/v1/users                    -> 201 {"message":"ok"}
rails> mallory@evil.example roles=Admin,Agent   system_init_done=true
basic-auth as the attacker            -> 200
```

Two anonymous requests, and the deployer is now locked out of their own setup
wizard. The marketplace listings tell the deployer to open the URL and complete
that wizard after the deploy, which is precisely the window.

Here `railway-seed-admin.rb` runs during database init, before rails, the
websocket server, the worker or nginx start:

```
[railway] admin admin@example.com created with roles Admin,Agent
[railway] setup complete, system_init_done=true
POST /api/v1/users -> 422 "This system has already been configured and an administrator account exists."
admin login -> 200 · wrong password -> 401
```

The container refuses to boot at all on an empty `ZAMMAD_ADMIN_PASSWORD`.

The password is re-seeded on **every** boot, so rotating it is a redeploy
(measured: new password 200 / old password 401 on the same database). Zammad
has no equivalent path — `createsuperuser`-style seeding is a first-boot-only
step in upstream's own tooling.

`fqdn` and `http_type` are set from the Railway domain at the same moment.
Stock deploys leave `fqdn` at `zammad.example.com`, which is what every
notification mail, password-reset link and OAuth callback is built from; the
marketplace listings make fixing it a manual post-deploy step in the admin UI.

## 2. Four roles, one container

Zammad's rails server, websocket server, background worker and nginx are the
same image and share no volume — attachments live in Postgres. The stock
compose topology becomes seven billed Railway services; this image runs all
four roles in one, so the template is three services (this + Postgres + Redis).

- nginx honours Railway's injected `$PORT` (Railway's HTTP healthcheck dials
  the injected port, not the domain's target port).
- The nginx resolver is written from `/etc/resolv.conf` with IPv6 brackets —
  Railway's private network is IPv6-only and the stock config declares no
  resolver.
- `MEMCACHE_SERVERS` is left unset, which makes Rails use Zammad's own file
  cache store (`Using Zammad's file store as Rails cache store.`) instead of a
  fourth service.
- Elasticsearch is off; Zammad falls back to database search.
- If any role exits, the container exits, so Railway restarts it rather than
  leaving a half-running help desk that still answers the healthcheck.

## Variables

| Variable | Default | Notes |
| --- | --- | --- |
| `ZAMMAD_ADMIN_PASSWORD` | — | required; boot fails if empty |
| `ZAMMAD_ADMIN_EMAIL` | `admin@example.com` | |
| `ZAMMAD_ADMIN_FIRSTNAME` / `_LASTNAME` | `Admin` / `User` | |
| `ZAMMAD_FQDN` | unset | set to the Railway public domain |
| `ZAMMAD_HTTP_TYPE` | `https` | |
| `ZAMMAD_ORGANIZATION` | `My Company` | |
| `ZAMMAD_ALLOW_SIGNUP` | `false` | Zammad ships public signup enabled |
| `POSTGRESQL_HOST` / `_PASS` | — | |
| `REDIS_URL` | — | websocket session store |

Upstream image is pinned by digest; Zammad's Postgres migrations run forward
only.
