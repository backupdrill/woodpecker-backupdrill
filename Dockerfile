# Node 24 is the LTS line supported until April 2028. Alpine 3.24 has the
# PostgreSQL 16 to 18 clients in its main repository, so no extra package
# repository has to be trusted, and the image stays small. The CLI's
# dependencies are plain JavaScript, so musl makes no difference to it.
FROM node:24-alpine3.24

# pg_dump must be at least the server's major version, and the entrypoint picks
# the one that matches the server so the dump can be restored onto that same
# version. 16 to 18 are the clients Alpine 3.24 ships, under 4 MB each.
RUN apk add --no-cache postgresql16-client postgresql17-client postgresql18-client

# The CLI gets the database password and the bucket keys, so the exact code is
# fixed at build time: package-lock.json pins backupdrill and every dependency,
# and a run downloads nothing.
WORKDIR /opt/backupdrill
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund && npm cache clean --force
COPY server-major.mjs ./
COPY --chmod=755 no-pg-dump ./

COPY --chmod=755 entrypoint.sh /usr/local/bin/woodpecker-backupdrill

LABEL org.opencontainers.image.source="https://github.com/backupdrill/woodpecker-backupdrill" \
      org.opencontainers.image.description="Woodpecker CI plugin: back up a Supabase or Postgres database to your own S3-compatible bucket" \
      org.opencontainers.image.licenses="MIT"

USER node
ENTRYPOINT ["/usr/local/bin/woodpecker-backupdrill"]
