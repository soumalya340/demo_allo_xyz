# Backend API + indexer. Build from the repo root:
#
#   docker build -t allo-backend .
#   docker run -p 3000:3000 -v allo-data:/app/data allo-backend
#
# Settings (all optional, defaults = BSC testnet, factory in Address.md), e.g.:
#   docker run -p 3000:3000 -v allo-data:/app/data \
#     -e RPC_URL=https://bsc-testnet-rpc.publicnode.com -e FACTORY_ADDRESS=0x... allo-backend
# The full list is in backend/API.md.

# ---- build: compile TypeScript with the dev dependencies (Nest CLI, tsc)
# Node >= 22.5 is needed for the built-in node:sqlite.
FROM node:24-slim AS build
WORKDIR /app
COPY backend/package.json backend/package-lock.json ./
RUN npm ci
COPY backend/nest-cli.json backend/tsconfig.json backend/tsconfig.build.json ./
COPY backend/src ./src
RUN npm run build && npm prune --omit=dev

# ---- run: compiled code + production dependencies only
FROM node:24-slim
WORKDIR /app
ENV NODE_ENV=production \
    PORT=3000 \
    DB_PATH=/app/data/allo.sqlite
COPY --from=build /app/package.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
# SQLite lives here; mount a volume so the indexed pools survive restarts.
RUN mkdir -p /app/data && chown node:node /app/data
VOLUME /app/data
USER node
EXPOSE 3000
CMD ["node", "dist/main.js"]
