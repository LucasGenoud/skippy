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

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: SCHEME_SCRIPT }} />
      </head>
      <body>{children}</body>
    </html>
  );
}
