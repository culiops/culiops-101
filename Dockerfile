# syntax=docker/dockerfile:1
#
# Multi-stage build. The "naive" one-stage version (see README) ships the full
# node:24 image + dev tooling and lands around ~1.6 GB. This version separates
# dependency install from the runtime image and uses -slim, landing ~330 MB
# (measured with `docker images`).
#
# Build for the platform Fargate actually runs (linux/amd64). On an Apple
# Silicon (M-series) Mac, `docker build` defaults to arm64 and your task will
# crash on Fargate with "exec format error". The build script passes
# --platform linux/amd64 for exactly this reason.

# ---- Stage 1: install production dependencies ----
FROM node:24-slim AS deps
WORKDIR /app
COPY app/package.json app/package-lock.json ./
# npm ci = reproducible install straight from the committed lockfile: exact,
# locked transitive deps, and it fails loudly if package.json and the lock drift.
RUN npm ci --omit=dev && npm cache clean --force

# ---- Stage 2: runtime ----
FROM node:24-slim AS runtime
ENV NODE_ENV=production
WORKDIR /app

# Copy only what we need: resolved deps + source. No npm cache, no dev deps.
COPY --from=deps /app/node_modules ./node_modules
COPY app/ ./

# Never run as root in a container. The node image ships a non-root `node` user.
USER node

EXPOSE 3000

# Container-level health check (separate from the ECS health check).
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "fetch('http://localhost:3000/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "server.js"]
