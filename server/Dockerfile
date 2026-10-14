FROM node:22-bookworm-slim AS build
WORKDIR /app
RUN corepack enable && corepack prepare pnpm@10.28.0 --activate
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile
COPY tsconfig.json tsconfig.build.json ./
COPY src ./src
RUN pnpm run build
# The Node adapter already belongs to this project's frozen lockfile. Copy only
# the runtime packages, dereferencing pnpm links, instead of shipping test tools.
RUN mkdir -p /runtime/node_modules/@hono \
    && cp -RL node_modules/hono /runtime/node_modules/hono \
    && cp -RL node_modules/zod /runtime/node_modules/zod \
    && cp -RL node_modules/@hono/node-server /runtime/node_modules/@hono/node-server

FROM node:22-bookworm-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production PORT=8787
COPY --chown=node:node package.json ./
COPY --from=build --chown=node:node /app/dist ./dist
COPY --from=build --chown=node:node /runtime/node_modules ./node_modules
USER node
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:8787/v1/health').then(async r=>{if(!r.ok||(await r.json()).status!=='ok')process.exit(1)}).catch(()=>process.exit(1))"
CMD ["node", "dist/dev-server.js"]
