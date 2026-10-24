# Backend API + indexer. Build from the repo root:
#
#   docker build -t allo-backend .
#   docker run -d --name allo --env-file .env -e PORT=3018 -p 3018:3018 -v allo-data:/app/data allo-backend
#
# Settings come from the repo-root .env via --env-file (it is never copied into the image, see
# .dockerignore); -e NAME=value overrides a single one. The root .env sets PORT=3000, so -e PORT=3018
# keeps the app on the port published below. Without --env-file the defaults are BSC testnet, the
# factory in Address.md and port 3018. The full list of settings is in backend/API.md.

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
    PORT=3018 \
    DB_PATH=/app/data/allo.sqlite
COPY --from=build /app/package.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
# SQLite lives here; mount a volume so the indexed pools survive restarts.
RUN mkdir -p /app/data && chown node:node /app/data
VOLUME /app/data
USER node
EXPOSE 3018
CMD ["node", "dist/main.js"]
