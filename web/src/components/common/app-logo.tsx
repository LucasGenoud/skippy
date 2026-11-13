const DEFAULT_SIZE = 28

/** The stacked sticky-notes mark, from /logo.svg so it stays crisp. */
export function AppLogo({ size = DEFAULT_SIZE, className }: { size?: number; className?: string }) {
  return (
    // A static SVG served as-is: next/image adds nothing in a static export.
    // eslint-disable-next-line @next/next/no-img-element
    <img src="/logo.svg" width={size} height={size} alt="Skippy logo" className={className} draggable={false} />
  )
}
