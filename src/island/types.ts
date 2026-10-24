export type IslandMode = "zen" | "compact" | "split" | "expanded";

export interface IslandSettings {
  hoverDelayMs: number;
  demoMusic: boolean;
  demoTimer: boolean;
}

export const DEFAULT_SETTINGS: IslandSettings = {
  hoverDelayMs: 150,
  demoMusic: true,
  demoTimer: true,
};

// Parameter pegas dari PRD (damped harmonic oscillator, via Framer Motion).
// Expand: sedikit membal (overshoot halus). Collapse: lebih cepat dan tegas.
export const SPRING_EXPAND = {
  type: "spring",
  stiffness: 380,
  damping: 28,
  mass: 0.8,
} as const;

export const SPRING_COLLAPSE = {
  type: "spring",
  stiffness: 450,
  damping: 35,
  mass: 0.7,
} as const;
