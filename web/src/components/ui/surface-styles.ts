// Class strings shared by the floating primitives, so menus, popovers,
// tooltips and dialogs read as one family and animate the same way.

/** Menus, popovers, hover cards, select lists: 8px, outlined, raised. */
export const floatingSurface =
  "rounded-lg border border-outline-variant bg-popover text-popover-foreground shadow-popover"

/**
 * In over BASE on the emphasized curve, out over FAST on the standard one,
 * fading and scaling from the trigger side (Motion.menu).
 */
export const floatingMotion =
  "data-[state=open]:animate-in data-[state=open]:fade-in-0 data-[state=open]:zoom-in-95 data-[state=open]:duration-240 data-[state=open]:ease-emphasized data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=closed]:zoom-out-95 data-[state=closed]:duration-150 data-[state=closed]:ease-standard data-[side=bottom]:slide-in-from-top-1 data-[side=left]:slide-in-from-right-1 data-[side=right]:slide-in-from-left-1 data-[side=top]:slide-in-from-bottom-1"

/** A row in a menu or list: a 4px tile inside the 8px menu, quiet hover. */
export const menuItem =
  "relative flex min-h-8 cursor-default items-center gap-2.5 rounded-sm px-2.5 py-1.5 text-sm text-on-surface outline-hidden select-none transition-colors duration-150 ease-standard focus:bg-hover data-[highlighted]:bg-hover active:bg-pressed data-[disabled]:pointer-events-none data-[disabled]:opacity-50 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4 [&_svg:not([class*='text-'])]:text-on-surface-variant"

/** The grey one-line hint beside a menu item's label (`MenuLabel`). */
export const menuDescription =
  "shrink-0 whitespace-nowrap text-xs text-on-surface-variant"

/** The scrim behind a modal: a quiet ink veil that fades. */
export const scrim =
  "fixed inset-0 z-50 bg-[#0D101A]/40 data-[state=open]:animate-in data-[state=open]:fade-in-0 data-[state=open]:duration-240 data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=closed]:duration-150"
