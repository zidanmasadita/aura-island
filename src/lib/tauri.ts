import { invoke as tauriInvoke } from "@tauri-apps/api/core";
import { listen as tauriListen, type UnlistenFn } from "@tauri-apps/api/event";

// Di luar Tauri (mis. `npm run dev` di browser biasa) semua helper ini
// menjadi no-op, sehingga UI tetap bisa dibuka untuk QA visual.
export const isTauri =
  typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

export async function safeInvoke<T>(
  cmd: string,
  args?: Record<string, unknown>,
): Promise<T | null> {
  if (!isTauri) return null;
  try {
    return await tauriInvoke<T>(cmd, args);
  } catch {
    return null;
  }
}

export async function safeListen(
  event: string,
  handler: () => void,
): Promise<UnlistenFn> {
  if (!isTauri) return () => {};
  try {
    return await tauriListen(event, handler);
  } catch {
    return () => {};
  }
}
