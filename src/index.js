import { handle } from "./hytapi.mjs";

export default {
  fetch: async (request, env, ctx) => handle(request, env, ctx)
};
