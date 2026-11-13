// Label presentation (`util/label_style.dart`): a curated icon set keyed by a
// stable string stored with the label, and colour resolution for chips.
// Never rename a key: labels that reference it would fall back to the default.

import {
  Zap,
  BookOpen,
  Bookmark,
  Briefcase,
  Bug,
  CalendarDays,
  Camera,
  Clapperboard,
  Code,
  DollarSign,
  Dumbbell,
  ExclamationMark,
  Flag,
  Gamepad2,
  Gift,
  GraduationCap,
  Heart,
  HeartPulse,
  House,
  Leaf,
  Lightbulb,
  Mail,
  Music,
  PawPrint,
  Phone,
  Plane,
  ShoppingCart,
  Star,
  Tag,
  User,
  Users,
  Utensils,
  type LucideIcon,
  type LucideProps,
} from "lucide-react";
import { createElement, type CSSProperties } from "react";

import { hexToRgb, rgbaHex } from "./color";

/** The glyph of a label with no icon of its own. */
export const DEFAULT_LABEL_ICON: LucideIcon = Tag;

/** The curated set, in picker order. */
export const LABEL_ICONS: Readonly<Record<string, LucideIcon>> = {
  star: Star,
  flag: Flag,
  favorite: Heart,
  bookmark: Bookmark,
  work: Briefcase,
  home: House,
  person: User,
  group: Users,
  school: GraduationCap,
  shopping: ShoppingCart,
  restaurant: Utensils,
  travel: Plane,
  fitness: Dumbbell,
  health: HeartPulse,
  money: DollarSign,
  idea: Lightbulb,
  code: Code,
  bug: Bug,
  book: BookOpen,
  music: Music,
  movie: Clapperboard,
  photo: Camera,
  game: Gamepad2,
  pets: PawPrint,
  nature: Leaf,
  gift: Gift,
  event: CalendarDays,
  call: Phone,
  mail: Mail,
  priority: ExclamationMark,
  bolt: Zap,
};

/** A label's icon for its key, or the default glyph. */
export function labelIconFor(key: string | null | undefined): LucideIcon {
  return (key ? LABEL_ICONS[key] : undefined) ?? DEFAULT_LABEL_ICON;
}

/** A label's icon as an element: `<LabelIcon iconKey="star" className="size-4" />`. */
export function LabelIcon({ iconKey, ...props }: LucideProps & { iconKey: string | null | undefined }) {
  return createElement(labelIconFor(iconKey), props);
}

/** A label's colour as "#RRGGBB", or null when unset or malformed. */
export function labelColor(hex: string | null | undefined): string | null {
  return hexToRgb(hex) ? (hex as string).toUpperCase() : null;
}

// A neutral badge: a translucent surface over whatever the card's fill is, the
// quiet edge, and the text colour. The label's own colour rides in
// `--label-tint` for its icon or dot (`text-(--label-tint)`), so a row of
// chips reads calm and the colour still tells them apart.
const CHIP_FILL = "color-mix(in srgb, var(--surface) 70%, transparent)";
const CHIP_EDGE = "color-mix(in srgb, var(--outline-variant), var(--on-surface) 6%)";

/** Inline colours for a label chip or marker of the given hex (or none). */
export function labelStyle(hex: string | null | undefined): CSSProperties {
  const rgb = hexToRgb(hex);
  return {
    color: "var(--on-surface)",
    backgroundColor: CHIP_FILL,
    borderColor: CHIP_EDGE,
    "--label-tint": rgb ? rgbaHex(rgb, 1).slice(0, 7) : "var(--on-surface-variant)",
  } as CSSProperties;
}
