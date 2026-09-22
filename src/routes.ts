import { createHash, timingSafeEqual } from "node:crypto";

import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";

import { MAX_LATENCY_MS, config } from "./config.js";
import {
  type ChaosProfile,
  UpstreamTimeoutError,
  callLedger,
  getChaosProfile,
  setChaosProfile,
} from "./upstream.js";

const startedAt = Date.now();

function digest(value: string): Buffer {
  return createHash("sha256").update(value).digest();
}

const chaosTokenDigest = digest(config.chaosToken);

function isAuthorized(request: FastifyRequest): boolean {
  const header = request.headers.authorization;
  if (typeof header !== "string" || !header.startsWith("Bearer ")) return false;
  // Hashing first keeps the comparison constant-length as well as constant-time.
  return timingSafeEqual(digest(header.slice("Bearer ".length)), chaosTokenDigest);
}

function routeLabel(request: FastifyRequest): string {
  return `${request.method} ${request.routeOptions.url ?? request.url}`;
}

/**
 * The one log line the CloudWatch metric filter and, later, Sentinel both key off.
 * Keep `event` and the field names stable — changing them silently breaks the alarm.
 */
function replyGatewayTimeout(
  request: FastifyRequest,
  reply: FastifyReply,
  error: UpstreamTimeoutError,
): FastifyReply {
  request.log.error(
    {
      event: "upstream.timeout",
      requestId: request.id,
      route: routeLabel(request),
      upstream: error.upstream,
      operation: error.operation,
      deadlineMs: error.deadlineMs,
      elapsedMs: error.elapsedMs,
      statusCode: 504,
    },
    "upstream call exceeded the request deadline",
  );

  return reply.code(504).send({
    error: "gateway_timeout",
    message: `The ${error.upstream} service did not answer within ${error.deadlineMs}ms.`,
    upstream: error.upstream,
    deadlineMs: error.deadlineMs,
    elapsedMs: error.elapsedMs,
    requestId: request.id,
  });
}

export async function registerRoutes(app: FastifyInstance): Promise<void> {
  app.get("/healthz", async () => ({
    status: "ok",
    service: config.serviceName,
    version: config.serviceVersion,
    uptimeSeconds: Math.round((Date.now() - startedAt) / 1000),
  }));

  app.get("/readyz", async (request, reply) => {
    try {
      await callLedger("ping", config.readinessDeadlineMs);
      return { status: "ready", upstream: "reachable" };
    } catch (error) {
      if (!(error instanceof UpstreamTimeoutError)) throw error;

      // Deliberately not `upstream.timeout`: probes run every few seconds and would
      // swamp the timeout metric with noise that no operator asked about.
      request.log.warn(
        {
          event: "readiness.degraded",
          requestId: request.id,
          route: routeLabel(request),
          upstream: error.upstream,
          deadlineMs: error.deadlineMs,
          elapsedMs: error.elapsedMs,
          statusCode: 503,
        },
        "readiness probe could not reach the upstream in time",
      );

      return reply.code(503).send({ status: "degraded", upstream: "unreachable" });
    }
  });

  app.get(
    "/api/orders/:orderId",
    {
      schema: {
        params: {
          type: "object",
          required: ["orderId"],
          properties: {
            orderId: { type: "string", pattern: "^[A-Za-z0-9_-]{1,64}$" },
          },
        },
      },
    },
    async (request, reply) => {
      const { orderId } = request.params as { orderId: string };

      try {
        const result = await callLedger(`orders.read:${orderId}`, config.requestDeadlineMs);
        return {
          orderId,
          status: "settled",
          upstreamLatencyMs: result.latencyMs,
          requestId: request.id,
        };
      } catch (error) {
        if (error instanceof UpstreamTimeoutError) return replyGatewayTimeout(request, reply, error);
        throw error;
      }
    },
  );

  app.get(
    "/api/slow",
    {
      schema: {
        querystring: {
          type: "object",
          properties: {
            ms: { type: "integer", minimum: 0, maximum: MAX_LATENCY_MS },
          },
        },
      },
    },
    async (request, reply) => {
      const { ms } = request.query as { ms?: number };
      const latencyMs = ms ?? config.upstreamLatencyMs;

      try {
        const result = await callLedger("slow", config.requestDeadlineMs, latencyMs);
        return { status: "ok", requestedMs: latencyMs, upstreamLatencyMs: result.latencyMs };
      } catch (error) {
        if (error instanceof UpstreamTimeoutError) return replyGatewayTimeout(request, reply, error);
        throw error;
      }
    },
  );

  app.register(async (admin) => {
    admin.addHook("onRequest", async (request, reply) => {
      if (isAuthorized(request)) return;

      request.log.warn(
        { event: "admin.unauthorized", requestId: request.id, route: routeLabel(request) },
        "rejected an unauthenticated admin request",
      );
      return reply.code(401).send({ error: "unauthorized" });
    });

    admin.get("/admin/chaos", async () => getChaosProfile());

    admin.post(
      "/admin/chaos",
      {
        schema: {
          body: {
            type: "object",
            additionalProperties: false,
            properties: {
              latencyMs: { type: "integer", minimum: 0, maximum: MAX_LATENCY_MS },
              jitterMs: { type: "integer", minimum: 0, maximum: MAX_LATENCY_MS },
              timeoutRate: { type: "number", minimum: 0, maximum: 1 },
            },
          },
        },
      },
      async (request) => {
        const profile = setChaosProfile(request.body as Partial<ChaosProfile>);

        request.log.info(
          { event: "chaos.updated", requestId: request.id, ...profile },
          "upstream behaviour changed",
        );
        return profile;
      },
    );
  });
}
