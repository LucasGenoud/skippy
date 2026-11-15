import type { NextConfig } from "next";
import pkg from "./package.json" with { type: "json" };

// Production is a static export the Rust server serves from `WEB`, falling
// back to index.html for every unknown path. `next dev` proxies /api to a
// local backend instead, so the dev server needs no CORS.
const isDev = process.env.NODE_ENV === "development";
const devBackend = process.env.SKIPPY_BACKEND ?? "http://localhost:8790";

const nextConfig: NextConfig = {
  output: isDev ? undefined : "export",
  trailingSlash: false,
  reactCompiler: true,
  images: { unoptimized: true },
  env: { NEXT_PUBLIC_SKIPPY_CLIENT_VERSION: pkg.version },
  ...(isDev
    ? {
        async rewrites() {
          return [{ source: "/api/:path*", destination: `${devBackend}/api/:path*` }];
        },
      }
    : {}),
};

export default nextConfig;
