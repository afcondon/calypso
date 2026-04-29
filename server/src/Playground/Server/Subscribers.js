import * as crypto from "node:crypto";

export const _freshId = () => {
  if (crypto && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  return "sub-" + Math.random().toString(36).slice(2, 14);
};
