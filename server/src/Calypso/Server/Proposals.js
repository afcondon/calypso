import * as crypto from "node:crypto";

export const _freshProposalIdRaw = () => {
  if (crypto && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  return "prop-" + Math.random().toString(36).slice(2, 14);
};

export const currentTimeMs = () => Date.now();
