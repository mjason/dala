/**
 * System-notification master switch (agent finished / needs approval /
 * question). Read at event time, so changes apply instantly.
 */
const KEY = "dala:notifications";

export function notificationsEnabled(): boolean {
  try {
    return localStorage.getItem(KEY) !== "off";
  } catch {
    return true;
  }
}

export function setNotificationsEnabled(on: boolean): void {
  try {
    localStorage.setItem(KEY, on ? "on" : "off");
  } catch {
    // storage unavailable
  }
}
