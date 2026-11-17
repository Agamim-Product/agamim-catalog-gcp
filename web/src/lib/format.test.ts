import {
  cellText,
  columnTypeLabel,
  formatBytes,
  formatDateTime,
  formatNumber,
  frequencyLabel,
  minutesSince,
  timeAgo,
} from "./format";

const NOW = new Date("2026-11-17T13:00:00Z");

describe("format helpers", () => {
  it("formats numbers and sizes, with a dash for missing values", () => {
    expect(formatNumber(2257)).toBe("2,257");
    expect(formatNumber(null)).toBe("—");
    expect(formatBytes(512)).toBe("512 B");
    expect(formatBytes(129611)).toBe("126.6 KB");
    expect(formatBytes(undefined)).toBe("—");
  });

  it("shows times in Israel time and handles bad input", () => {
    expect(formatDateTime("2026-11-17T12:00:00Z")).toContain("14:00");
    expect(formatDateTime("not a date")).toBe("—");
    expect(formatDateTime(null)).toBe("—");
  });

  it("says how long ago, in Hebrew", () => {
    expect(timeAgo("2026-11-17T12:55:00Z", NOW)).toContain("5");
    expect(timeAgo("2026-11-17T10:00:00Z", NOW)).toContain("3");
    expect(timeAgo("2026-11-15T13:00:00Z", NOW)).toContain("שלשום");
    expect(timeAgo("2026-11-17T12:59:50Z", NOW)).not.toBe("—");
    expect(timeAgo(null, NOW)).toBe("—");
    expect(minutesSince("2026-11-17T12:00:00Z", NOW)).toBe(60);
    expect(minutesSince(null, NOW)).toBeNull();
  });

  it("translates frequencies and column types, keeping unknown values", () => {
    expect(frequencyLabel("Times in day")).toBe("כמה פעמים ביום");
    expect(frequencyLabel("Hourly-ish")).toBe("Hourly-ish");
    expect(frequencyLabel(null)).toBe("לא צוין");
    expect(columnTypeLabel("numeric")).toBe("מספר");
    expect(columnTypeLabel("geometry")).toBe("geometry");
  });

  it("renders any cell value as text", () => {
    expect(cellText("LY")).toBe("LY");
    expect(cellText(3)).toBe("3");
    expect(cellText(true)).toBe("true");
    expect(cellText(null)).toBe("—");
    expect(cellText("")).toBe("—");
    expect(cellText({ a: 1 })).toBe('{"a":1}');
  });
});
