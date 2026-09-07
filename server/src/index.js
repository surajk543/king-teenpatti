import http from 'node:http';
import path from 'node:path';
import express from 'express';
import { Server } from 'socket.io';
import config from './config/index.js';
import { monitorEventLoopDelay } from 'node:perf_hooks';
import { openDatabase, closeDatabase, getPool } from './db/index.js';
import { authRoutes, playerRoutes } from './auth/routes.js';
import { AuthError } from './auth/providers.js';
import { GameError } from './game/table.js';
import RoomManager from './game/roomManager.js';
import { attachSocketHandlers } from './socket/index.js';
import logger from './util/logger.js';
import { bindPool, bindRooms, httpMetricsMiddleware, metricsHandler } from './metrics/index.js';

export async function createServer() {
  await openDatabase();

  const app = express();
  app.disable('x-powered-by');
  // Node's own query-string parser rather than Express's default `qs`. The two
  // query parameters this API reads (`limit`, `category`) are plain scalars,
  // and it keeps `qs` — which has open advisories with no patched release
  // yet — out of the request path altogether.
  app.set('query parser', 'simple');
  // Requirement 35: every response is counted and timed by route pattern.
  if (config.metrics.enabled) app.use(httpMetricsMiddleware());
  app.use(express.json({ limit: '32kb' }));

  const rooms = new RoomManager();
  bindRooms(rooms);
  bindPool(getPool);
  if (config.metrics.enabled) app.get(config.metrics.path, metricsHandler());

  // Health carries the process's own vital signs as well as the room counts,
  // so a load test — or a dashboard — can watch memory, CPU and event-loop
  // lag from outside without a shell on the host. CPU is the share of one core
  // used since the previous /health call, so a poller sees a running average
  // over its own interval; loop-lag percentiles cover the same span.
  const loopDelay = monitorEventLoopDelay({ resolution: 20 });
  loopDelay.enable();
  let cpuMark = process.cpuUsage();
  let cpuMarkAt = process.hrtime.bigint();
  app.get('/health', (req, res) => {
    const mem = process.memoryUsage();
    const cpu = process.cpuUsage(cpuMark);
    const now = process.hrtime.bigint();
    const elapsedUs = Number(now - cpuMarkAt) / 1000;
    cpuMark = process.cpuUsage();
    cpuMarkAt = now;
    const mb = (bytes) => Math.round(bytes / 1048576 * 10) / 10;
    const ns = (v) => Math.round(v / 1e6 * 10) / 10;
    let db = null;
    try {
      const pool = getPool();
      db = { total: pool.totalCount, idle: pool.idleCount, waiting: pool.waitingCount };
    } catch {
      // Not open yet — nothing to report.
    }
    res.json({
      ok: true,
      uptime: process.uptime(),
      ...rooms.stats(),
      sockets: io.engine?.clientsCount ?? null,
      process: {
        pid: process.pid,
        node: process.version,
        rssMb: mb(mem.rss),
        heapUsedMb: mb(mem.heapUsed),
        heapTotalMb: mb(mem.heapTotal),
        externalMb: mb(mem.external),
        cpuPercent: elapsedUs > 0 ? Math.round((cpu.user + cpu.system) / elapsedUs * 1000) / 10 : 0,
        loopLagP50Ms: ns(loopDelay.percentile(50)),
        loopLagP99Ms: ns(loopDelay.percentile(99)),
        loopLagMaxMs: ns(loopDelay.max),
      },
      db,
    });
    loopDelay.reset();
  });

  app.use('/api/auth', authRoutes());
  // Rewards and profile pictures. Seating is checked live, so the avatar
  // endpoint can refuse a change while the player is at a table.
  app.use('/api', playerRoutes({ isSeated: (userId) => Boolean(rooms.getTableForPlayer(userId)) }));

  app.get('/api/rooms', (req, res) => {
    // ?category=blind|seen filters the lobby to one category.
    const category = req.query.category === 'blind' || req.query.category === 'seen'
      ? req.query.category
      : null;

    res.json({
      tables: rooms.listTables({ category }),
      options: RoomManager.lobbyOptions(),
    });
  });

  // Bundled browser client — a zero-build reference client.
  app.use(express.static(path.join(config.rootDir, 'public')));

  app.use((error, req, res, next) => {
    if (error instanceof AuthError) {
      return res.status(error.status).json({ error: error.code, message: error.message });
    }
    if (error instanceof GameError) {
      return res.status(400).json({ error: error.code, message: error.message });
    }
    logger.error('request failed', { path: req.path, error: error.message, stack: error.stack });
    return res.status(500).json({ error: 'internal_error', message: 'Something went wrong' });
  });

  const server = http.createServer(app);

  const io = new Server(server, {
    cors: { origin: config.corsOrigin, methods: ['GET', 'POST'] },
    // WebSocket first; long-polling stays available so restrictive mobile
    // networks and WebGL builds behind proxies can still connect.
    transports: ['websocket', 'polling'],
    pingInterval: 20000,
    pingTimeout: 25000,
    maxHttpBufferSize: 1e5,
  });

  if (config.redisUrl) {
    const { createAdapter } = await import('@socket.io/redis-adapter');
    const { createClient } = await import('redis');
    const pubClient = createClient({ url: config.redisUrl });
    const subClient = pubClient.duplicate();
    await Promise.all([pubClient.connect(), subClient.connect()]);
    io.adapter(createAdapter(pubClient, subClient));
    logger.info('socket.io redis adapter enabled');
  }

  attachSocketHandlers(io, rooms);

  return { app, server, io, rooms };
}

const isEntrypoint = process.argv[1] && import.meta.url === `file://${path.resolve(process.argv[1])}`;

if (isEntrypoint) {
  const { server, rooms, io } = await createServer();

  server.listen(config.port, config.host, () => {
    logger.info('king-teenpatti server listening', {
      url: `http://${config.host}:${config.port}`,
      env: config.env,
      welcomeChips: config.game.welcomeChips,
      boot: config.game.bootAmount,
    });
  });

  const shutdown = async (signal) => {
    logger.info('shutting down', { signal });
    setTimeout(() => process.exit(1), 8000).unref();
    io.close();
    // Live hands are settled (their pots paid out) before the pool closes.
    await rooms.shutdown();
    await new Promise((resolve) => server.close(resolve));
    await closeDatabase();
    process.exit(0);
  };

  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('unhandledRejection', (reason) => logger.error('unhandled rejection', { reason: String(reason) }));
}

export default createServer;
