import { cloudflareTest } from "@cloudflare/vitest-pool-workers"
import { defineConfig } from "vitest/config"

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        bindings: {
          OPENCODE_API_KEY: "test-provider-key",
          LEARNFOLD_HOSTED_ACCESS_TOKEN: "test-access-token",
        },
      },
    }),
  ],
})
