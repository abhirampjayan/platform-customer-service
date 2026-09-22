import pino from "pino";

import { config } from "./config.js";

/**
 * One JSON object per line, no pretty transport in any environment: the CloudWatch metric
 * filter matches on `$.event`, which only works while the line is raw JSON.
 */
export const logger = pino({
  level: config.logLevel,
  timestamp: pino.stdTimeFunctions.isoTime,
  formatters: {
    level: (label) => ({ level: label }),
  },
  base: {
    service: config.serviceName,
    env: config.nodeEnv,
    version: config.serviceVersion,
  },
  redact: {
    paths: ["req.headers.authorization", "req.headers.cookie"],
    censor: "[redacted]",
  },
});
