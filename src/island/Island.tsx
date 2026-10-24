import { useCallback, useEffect, useRef, useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { isTauri, safeInvoke, safeListen } from "../lib/tauri";
import {
  DEFAULT_SETTINGS,
  SPRING_COLLAPSE,
  SPRING_EXPAND,
  type IslandMode,
  type IslandSettings,
} from "./types";

// Geometri dari PRD (px). Split = kapsul utama 160 + gap 8 + bubble 36.
const SIZES: Record<Exclude<IslandMode, "expanded">, { w: number; h: number; main: number }> = {
  zen: { w: 120, h: 4, main: 120 },
  compact: { w: 180, h: 36, main: 180 },
  split: { w: 204, h: 36, main: 160 },
};
const GAP = 8;
const BUBBLE = 36;
const CARD_W = 420;
const CARD_H = 180;
const POMODORO_SECONDS = 25 * 60;
const DEMO_TRACK_SECONDS = 227; // 3:47

function formatTime(total: number) {
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${m}:${s.toString().padStart(2, "0")}`;
}

function loadSettings(): IslandSettings {
  try {
    const raw = localStorage.getItem("aura-settings");
    if (raw) return { ...DEFAULT_SETTINGS, ...JSON.parse(raw) };
  } catch {
    // Abaikan, pakai default.
  }
  return DEFAULT_SETTINGS;
}

export default function Island() {
  const [mode, setMode] = useState<IslandMode>("compact");
  const [settings, setSettings] = useState<IslandSettings>(loadSettings);
  const [playing, setPlaying] = useState(true);
  const [progress, setProgress] = useState(37);
  const [timerLeft, setTimerLeft] = useState(POMODORO_SECONDS);
  const [autoStart, setAutoStart] = useState(false);

  const modeRef = useRef(mode);
  modeRef.current = mode;
  const prevModeRef = useRef<Exclude<IslandMode, "expanded">>("compact");
  const hoverTimerRef = useRef<number | undefined>(undefined);
  const capsuleRef = useRef<HTMLDivElement>(null);
  const cardRef = useRef<HTMLDivElement>(null);

  const collapse = useCallback(() => {
    setMode(prevModeRef.current);
  }, []);

  const expand = useCallback(() => {
    if (modeRef.current !== "expanded") {
      prevModeRef.current = modeRef.current as Exclude<IslandMode, "expanded">;
      setMode("expanded");
    }
  }, []);

  const toggleExpand = useCallback(() => {
    if (modeRef.current === "expanded") {
      collapse();
    } else {
      expand();
    }
  }, [collapse, expand]);

  // Persist settings (localStorage WebView2; cukup untuk Fase 1).
  useEffect(() => {
    try {
      localStorage.setItem("aura-settings", JSON.stringify(settings));
    } catch {
      // Abaikan.
    }
  }, [settings]);

  // Event dari Rust: tray "Perluas / Ciutkan Pulau".
  useEffect(() => {
    let unlisten: (() => void) | undefined;
    safeListen("toggle-expand", toggleExpand).then((fn) => {
      unlisten = fn;
    });
    return () => unlisten?.();
  }, [toggleExpand]);

  // Global hotkey Ctrl+Alt+I (hanya di Tauri).
  useEffect(() => {
    if (!isTauri) return;
    let cancelled = false;
    import("@tauri-apps/plugin-global-shortcut")
      .then(async ({ register, unregister }) => {
        if (cancelled) return;
        await register("Ctrl+Alt+I", (event) => {
          if (event.state === "Pressed") toggleExpand();
        }).catch(() => {});
        return () => unregister("Ctrl+Alt+I").catch(() => {});
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [toggleExpand]);

  // Status autostart (hanya di Tauri).
  useEffect(() => {
    if (!isTauri) return;
    import("@tauri-apps/plugin-autostart")
      .then(({ isEnabled }) => isEnabled().then(setAutoStart).catch(() => {}))
      .catch(() => {});
  }, []);

  // Pomodoro demo: hitung mundur, loop saat habis.
  useEffect(() => {
    if (!settings.demoTimer) return;
    const id = window.setInterval(() => {
      setTimerLeft((t) => (t <= 0 ? POMODORO_SECONDS : t - 1));
    }, 1000);
    return () => window.clearInterval(id);
  }, [settings.demoTimer]);

  // Laporkan rect pulau ke Rust untuk WM_NCHITTEST (click-through).
  const reportRect = useCallback(() => {
    const el = modeRef.current === "expanded" ? cardRef.current : capsuleRef.current;
    if (!el) return;
    const r = el.getBoundingClientRect();
    void safeInvoke("set_island_rect", {
      rect: { x: r.left, y: r.top, width: r.width, height: r.height },
    });
  }, []);

  useEffect(() => {
    const raf = requestAnimationFrame(() => {
      // Tunggu satu frame agar animasi Framer Motion sempat mengukur layout.
      reportRect();
      window.setTimeout(reportRect, 350);
    });
    return () => cancelAnimationFrame(raf);
  }, [mode, reportRect]);

  useEffect(() => {
    window.addEventListener("resize", reportRect);
    return () => window.removeEventListener("resize", reportRect);
  }, [reportRect]);

  const clearHoverTimer = () => {
    if (hoverTimerRef.current !== undefined) {
      window.clearTimeout(hoverTimerRef.current);
      hoverTimerRef.current = undefined;
    }
  };

  const handleCapsuleEnter = () => {
    if (modeRef.current === "compact" || modeRef.current === "split") {
      clearHoverTimer();
      hoverTimerRef.current = window.setTimeout(expand, settings.hoverDelayMs);
    }
  };

  const handleCapsuleLeave = () => {
    clearHoverTimer();
  };

  const handleCapsuleClick = () => {
    clearHoverTimer();
    toggleExpand();
  };

  const handleZenClick = () => {
    setMode("compact");
  };

  const toggleAutoStart = async (checked: boolean) => {
    setAutoStart(checked);
    if (!isTauri) return;
    try {
      const mod = await import("@tauri-apps/plugin-autostart");
      if (checked) await mod.enable();
      else await mod.disable();
    } catch {
      setAutoStart(!checked);
    }
  };

  const showSplitBubble = mode === "split" && settings.demoTimer;
  const effectiveMode: Exclude<IslandMode, "expanded"> =
    mode === "expanded" ? prevModeRef.current : mode;

  return (
    <>
      {/* Definisi filter gooey PRD: blur 8px + alpha matrix 20/-10. */}
      <svg width="0" height="0" style={{ position: "absolute" }} aria-hidden="true">
        <defs>
          <filter id="aura-gooey">
            <feGaussianBlur in="SourceGraphic" stdDeviation="8" result="blur" />
            <feColorMatrix
              in="blur"
              mode="matrix"
              values="1 0 0 0 0  0 1 0 0 0  0 0 1 0 0  0 0 0 20 -10"
              result="gooey"
            />
            <feComposite in="SourceGraphic" in2="gooey" operator="atop" />
          </filter>
        </defs>
      </svg>

      <AnimatePresence>
        {mode !== "expanded" ? (
          <motion.div
            key="capsule"
            ref={capsuleRef}
            className="flex items-center"
            style={{
              gap: GAP,
              filter: mode === "split" ? "url(#aura-gooey)" : undefined,
              cursor: "pointer",
            }}
            initial={false}
            animate={{ width: SIZES[effectiveMode].w, height: SIZES[effectiveMode].h }}
            transition={effectiveMode === "zen" ? SPRING_COLLAPSE : SPRING_EXPAND}
            onMouseEnter={handleCapsuleEnter}
            onMouseLeave={handleCapsuleLeave}
            onClick={mode === "zen" ? handleZenClick : handleCapsuleClick}
          >
            <motion.div
              className="island-body flex items-center justify-between px-3"
              initial={false}
              animate={{
                width: SIZES[effectiveMode].main,
                height: SIZES[effectiveMode].h,
              }}
              transition={SPRING_EXPAND}
            >
              {effectiveMode !== "zen" && (
                <>
                  <span
                    className={`inline-block h-2 w-2 shrink-0 rounded-full ${
                      settings.demoMusic && playing ? "bg-green-400 pulse-dot" : "bg-zinc-500"
                    }`}
                  />
                  {settings.demoMusic && playing ? (
                    <span className="flex h-3.5 items-end gap-[3px]" aria-hidden="true">
                      {[0, 1, 2, 3, 4].map((i) => (
                        <span
                          key={i}
                          className="eq-bar w-[3px] rounded-full bg-white/90"
                          style={{
                            height: "100%",
                            animationDelay: `${i * 0.13}s`,
                            animationDuration: `${0.7 + i * 0.09}s`,
                          }}
                        />
                      ))}
                    </span>
                  ) : (
                    <span className="text-[10px] tracking-wide text-white/50">
                      Aura Island
                    </span>
                  )}
                </>
              )}
            </motion.div>

            {showSplitBubble && (
              <motion.div
                className="island-body flex items-center justify-center"
                style={{ width: BUBBLE, height: BUBBLE }}
                initial={{ scale: 0 }}
                animate={{ scale: 1 }}
                transition={SPRING_EXPAND}
              >
                <span className="font-mono text-[10px] font-semibold text-white">
                  {formatTime(timerLeft)}
                </span>
              </motion.div>
            )}
          </motion.div>
        ) : (
          <motion.div
            key="card"
            ref={cardRef}
            className="island-card flex flex-col gap-3 p-4"
            style={{ width: CARD_W, height: CARD_H }}
            initial={{ opacity: 0, scale: 0.92 }}
            animate={{ opacity: 1, scale: 1 }}
            exit={{ opacity: 0, scale: 0.92 }}
            transition={SPRING_EXPAND}
            onMouseLeave={collapse}
          >
            <div className="flex items-center gap-3">
              <div
                className="h-16 w-16 shrink-0 rounded-2xl"
                style={{
                  background:
                    "linear-gradient(135deg, #7c3aed 0%, #db2777 55%, #f59e0b 100%)",
                }}
              />
              <div className="min-w-0 flex-1">
                <p className="truncate text-sm font-semibold text-white">
                  Judul Lagu (demo)
                </p>
                <p className="truncate text-xs text-white/60">Artis (demo)</p>
                <p className="mt-1 text-[10px] text-white/40">
                  Kontrol media asli hadir di Fase 2 (GSMTC).
                </p>
              </div>
              <button
                type="button"
                onClick={collapse}
                className="shrink-0 rounded-full px-2 py-1 text-xs text-white/70 hover:bg-white/10"
              >
                Ciutkan
              </button>
            </div>

            <div className="flex items-center justify-center gap-4">
              <button
                type="button"
                aria-label="Sebelumnya"
                className="text-white/80 hover:text-white"
                onClick={() => setProgress((p) => Math.max(0, p - 10))}
              >
                <svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor">
                  <rect x="5" y="5" width="2.5" height="14" rx="1" />
                  <path d="M20 5 L9 12 L20 19 Z" />
                </svg>
              </button>
              <button
                type="button"
                aria-label={playing ? "Jeda" : "Putar"}
                className="flex h-10 w-10 items-center justify-center rounded-full bg-white text-black hover:bg-zinc-200"
                onClick={() => setPlaying((p) => !p)}
              >
                {playing ? (
                  <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor">
                    <rect x="6" y="5" width="4" height="14" rx="1" />
                    <rect x="14" y="5" width="4" height="14" rx="1" />
                  </svg>
                ) : (
                  <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor">
                    <path d="M8 5 L19 12 L8 19 Z" />
                  </svg>
                )}
              </button>
              <button
                type="button"
                aria-label="Berikutnya"
                className="text-white/80 hover:text-white"
                onClick={() => setProgress((p) => Math.min(100, p + 10))}
              >
                <svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor">
                  <rect x="16.5" y="5" width="2.5" height="14" rx="1" />
                  <path d="M4 5 L15 12 L4 19 Z" />
                </svg>
              </button>
            </div>

            <div className="flex items-center gap-2 text-[10px] text-white/60">
              <span className="w-8 text-right">
                {formatTime(Math.round((progress / 100) * DEMO_TRACK_SECONDS))}
              </span>
              <input
                type="range"
                min={0}
                max={100}
                value={progress}
                onChange={(e) => setProgress(Number(e.target.value))}
                className="h-1 flex-1 cursor-pointer appearance-none rounded-full bg-white/20 accent-white"
              />
              <span className="w-8">{formatTime(DEMO_TRACK_SECONDS)}</span>
            </div>

            <div className="mt-auto flex flex-wrap items-center gap-x-4 gap-y-1 border-t border-white/10 pt-2 text-[11px] text-white/70">
              <label className="flex items-center gap-1.5">
                Hover
                <input
                  type="number"
                  min={0}
                  max={1000}
                  step={50}
                  value={settings.hoverDelayMs}
                  onChange={(e) =>
                    setSettings((s) => ({
                      ...s,
                      hoverDelayMs: Number(e.target.value),
                    }))
                  }
                  className="w-16 rounded bg-white/10 px-1.5 py-0.5 text-white outline-none"
                />
                ms
              </label>
              <label className="flex items-center gap-1.5">
                <input
                  type="checkbox"
                  checked={autoStart}
                  onChange={(e) => void toggleAutoStart(e.target.checked)}
                />
                Mulai otomatis
              </label>
              <label className="flex items-center gap-1.5">
                <input
                  type="checkbox"
                  checked={settings.demoMusic}
                  onChange={(e) =>
                    setSettings((s) => ({ ...s, demoMusic: e.target.checked }))
                  }
                />
                Demo musik
              </label>
              <label className="flex items-center gap-1.5">
                <input
                  type="checkbox"
                  checked={settings.demoTimer}
                  onChange={(e) =>
                    setSettings((s) => ({ ...s, demoTimer: e.target.checked }))
                  }
                />
                Demo timer
              </label>
              <button
                type="button"
                onClick={() => setMode("zen")}
                className="ml-auto rounded-full px-2 py-1 text-white/70 hover:bg-white/10"
              >
                Zen
              </button>
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </>
  );
}
