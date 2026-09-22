import { randomUUID } from "node:crypto";

import Fastify, { type FastifyBaseLogger } from "fastify";

import { config } from "./config.js";
import { logger } from "./logger.js";
import { registerRoutes } from "./routes.js";

const app = Fastify({
  // Cast so the instance keeps Fastify's default logger type; a concrete pino generic
  // leaks into every route signature and stops plugins from type-checking.
  loggerInstance: logger as FastifyBaseLogger,
  genReqId: () => randomUUID(),
  bodyLimit: 16 * 1024,
  // A backstop above the application deadline: a socket that hangs for some reason the
  // deadline never sees still gets reclaimed rather than pinning a connection.
  requestTimeout: config.requestDeadlineMs + 5_000,
  connectionTimeout: config.requestDeadlineMs + 10_000,
});

await registerRoutes(app);

app.setNotFoundHandler(async (_request, reply) => reply.code(404).send({ error: "not_found" }));

async function shutdown(signal: NodeJS.Signals) {
  app.log.info({ event: "server.stopping", signal }, "shutting down");
  try {
    await app.close();
    process.exit(0);
  } catch (error) {
    app.log.error({ event: "server.stop_failed", err: error }, "shutdown did not complete cleanly");
    process.exit(1);
  }
}

for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.on(signal, () => void shutdown(signal));
}

try {
  await app.listen({ port: config.port, host: config.host });
  app.log.info(
    {
      event: "server.started",
      port: config.port,
      requestDeadlineMs: config.requestDeadlineMs,
    },
    "timeout-service is listening",
  );
} catch (error) {
  app.log.error({ event: "server.start_failed", err: error }, "could not start");
  process.exit(1);
}
