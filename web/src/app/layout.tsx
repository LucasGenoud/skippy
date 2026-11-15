import type { Metadata, Viewport } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Skippy",
  description: "Notes, checklists, and boards",
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  viewportFit: "cover",
};

// Paints the last used scheme before the app mounts, so a dark theme does not
// flash light. ThemeSync keeps the key current.
const SCHEME_SCRIPT = `try{var s=localStorage.getItem("skippy_scheme");if(!s){s=matchMedia("(prefers-color-scheme: dark)").matches?"dark":"light"}if(s==="dark"){document.documentElement.classList.add("dark")}document.documentElement.style.colorScheme=s}catch(e){}`;

// The default UI font's weights in use (400 body, 500 controls, 600 titles).
// Fetched up front, so the first grid is not laid out in the fallback font
// and then reflowed when Inter arrives.
const PRELOADED_FONTS = ["Inter-Regular", "Inter-Medium", "Inter-SemiBold"] as const;

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: SCHEME_SCRIPT }} />
        {PRELOADED_FONTS.map((name) => (
          <link key={name} rel="preload" href={`/fonts/Inter/${name}.ttf`} as="font" type="font/ttf" crossOrigin="anonymous" />
        ))}
      </head>
      <body>{children}</body>
    </html>
  );
}
