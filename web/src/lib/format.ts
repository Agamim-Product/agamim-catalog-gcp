// Hebrew formatting helpers. All times are shown in Israel time.

const TZ = "Asia/Jerusalem";

const dateTime = new Intl.DateTimeFormat("he-IL", {
  timeZone: TZ,
  day: "2-digit",
  month: "2-digit",
  year: "numeric",
  hour: "2-digit",
  minute: "2-digit",
});

const time = new Intl.DateTimeFormat("he-IL", { timeZone: TZ, hour: "2-digit", minute: "2-digit" });
const day = new Intl.DateTimeFormat("he-IL", { timeZone: TZ, weekday: "short", day: "2-digit", month: "2-digit" });
const integer = new Intl.NumberFormat("he-IL");
const relative = new Intl.RelativeTimeFormat("he", { numeric: "auto" });

function parse(iso: string | null | undefined): Date | null {
  if (!iso) return null;
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? null : d;
}

export function formatDateTime(iso: string | null | undefined): string {
  const d = parse(iso);
  return d ? dateTime.format(d) : "—";
}

export function formatTime(iso: string | null | undefined): string {
  const d = parse(iso);
  return d ? time.format(d) : "—";
}

export function formatDay(iso: string | null | undefined): string {
  const d = parse(iso);
  return d ? day.format(d) : "—";
}

const LOCAL = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})/;
const dayUtc = new Intl.DateTimeFormat("he-IL", { timeZone: "UTC", weekday: "short", day: "2-digit", month: "2-digit" });

/** Flight times are already Tel Aviv time, stored without a time zone. They are shown as they are, never converted. */
export function formatLocalTime(value: string | null | undefined): string {
  const m = value ? LOCAL.exec(value) : null;
  return m ? `${m[4] ?? ""}:${m[5] ?? ""}` : "—";
}

export function formatLocalDay(value: string | null | undefined): string {
  const m = value ? LOCAL.exec(value) : null;
  return m ? dayUtc.format(new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])))) : "—";
}

export function formatLocalDateTime(value: string | null | undefined): string {
  const m = value ? LOCAL.exec(value) : null;
  return m ? `${m[3] ?? ""}/${m[2] ?? ""}/${m[1] ?? ""} ${m[4] ?? ""}:${m[5] ?? ""}` : "—";
}

export function formatNumber(n: number | null | undefined): string {
  return n === null || n === undefined ? "—" : integer.format(n);
}

export function formatBytes(n: number | null | undefined): string {
  if (n === null || n === undefined) return "—";
  const units = ["B", "KB", "MB", "GB"];
  let value = n;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value.toFixed(unit === 0 ? 0 : 1)} ${units[unit] ?? "B"}`;
}

/** "לפני 5 דקות", "לפני שעתיים", ... relative to now. */
export function timeAgo(iso: string | null | undefined, now: Date = new Date()): string {
  const d = parse(iso);
  if (!d) return "—";
  const seconds = Math.round((d.getTime() - now.getTime()) / 1000);
  const abs = Math.abs(seconds);
  if (abs < 60) return relative.format(seconds, "second");
  if (abs < 3600) return relative.format(Math.round(seconds / 60), "minute");
  if (abs < 86400) return relative.format(Math.round(seconds / 3600), "hour");
  return relative.format(Math.round(seconds / 86400), "day");
}

/** Minutes since the given time; null when unknown. */
export function minutesSince(iso: string | null | undefined, now: Date = new Date()): number | null {
  const d = parse(iso);
  return d ? Math.max(0, Math.round((now.getTime() - d.getTime()) / 60000)) : null;
}

const FREQUENCY: Record<string, string> = {
  "Times in day": "כמה פעמים ביום",
  Daily: "יומי",
  Weekly: "שבועי",
  Monthly: "חודשי",
  Quarterly: "רבעוני",
  Year: "שנתי",
  Yearly: "שנתי",
  NotConstant: "לא קבוע",
};

export function frequencyLabel(value: string | null | undefined): string {
  if (!value) return "לא צוין";
  return FREQUENCY[value] ?? value;
}

const COLUMN_TYPES: Record<string, string> = {
  text: "טקסט",
  numeric: "מספר",
  int: "מספר שלם",
  int4: "מספר שלם",
  int8: "מספר שלם",
  float8: "מספר עשרוני",
  timestamp: "תאריך ושעה",
  date: "תאריך",
  bool: "כן/לא",
};

export function columnTypeLabel(type: string): string {
  return COLUMN_TYPES[type] ?? type;
}

export function cellText(value: unknown): string {
  if (value === null || value === undefined || value === "") return "—";
  if (typeof value === "string") return LOCAL.test(value) ? value.replace("T", " ") : value;
  if (typeof value === "number" || typeof value === "boolean" || typeof value === "bigint") return value.toString();
  return JSON.stringify(value);
}
