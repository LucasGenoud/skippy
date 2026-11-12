"use client";

import dynamic from "next/dynamic";

// The app renders on the client only: the static export has one HTML entry,
// and every store reads browser storage. Nothing renders on the server, so
// there is nothing to mismatch on hydration.
export const AppLoader = dynamic(() => import("./app").then((m) => m.App), { ssr: false });
