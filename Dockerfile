# Node 24 is the LTS line supported until April 2028. Alpine 3.24 has the
# PostgreSQL 18 client in its main repository, so no extra apt/apk repository
# has to be trusted, and the image stays small. The CLI's dependencies are plain
# JavaScript, so musl makes no difference to it.
FROM node:24-alpine3.24

# pg_dump must be at least the server's major version. 18 is the newest one
# Alpine 3.24 ships, and it still dumps servers back to PostgreSQL 9.2.
ARG PG_MAJOR=18
RUN apk add --no-cache "postgresql${PG_MAJOR}-client"

COPY --chmod=755 entrypoint.sh /usr/local/bin/woodpecker-backupdrill

LABEL org.opencontainers.image.source="https://github.com/backupdrill/woodpecker-backupdrill" \
      org.opencontainers.image.description="Woodpecker CI plugin: back up a Supabase or Postgres database to your own S3-compatible bucket" \
      org.opencontainers.image.licenses="MIT"

USER node
ENTRYPOINT ["/usr/local/bin/woodpecker-backupdrill"]
