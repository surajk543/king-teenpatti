import http from 'node:http';
import path from 'node:path';
import express from 'express';
import { Server } from 'socket.io';
import config from './config/index.js';
import { openDatabase, closeDatabase } from './db/index.js';
import { authRoutes } from './auth/routes.js';
import { AuthError } from './auth/providers.js';
import { GameError } from './game/table.js';
import RoomManager from './game/roomManager.js';
import { attachSocketHandlers } from './socket/index.js';
import logger from './util/logger.js';

export async function createServer() {
  openDatabase();

  const app = express();
  app.disable('x-powered-by');
  app.use(express.json({ limit: '32kb' }));

  const rooms = new RoomManager();

  app.get('/health', (req, res) => {
    res.json({ ok: true, uptime: process.uptime(), ...rooms.stats() });
  });

  app.use('/api/auth', authRoutes());

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

  // Bundled browser client — lets you play in a tab without a Unity build.
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

  const shutdown = (signal) => {
    logger.info('shutting down', { signal });
    io.close();
    rooms.shutdown();
    server.close(() => {
      closeDatabase();
      process.exit(0);
    });
    setTimeout(() => process.exit(1), 8000).unref();
  };

  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('unhandledRejection', (reason) => logger.error('unhandled rejection', { reason: String(reason) }));
}

export default createServer;
