import * as crypto from "node:crypto";

export const sha1Hex = (input) => () =>
  crypto.createHash("sha1").update(input, "utf8").digest("hex");
