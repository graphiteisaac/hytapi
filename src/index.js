import { fetch } from "./hytapi.mjs";

export default {
  async fetch(request, env, ctx) {
    return fetch(request, env, ctx);
  },
};
