import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { ApiError, api, getJson } from "./api/client";
import { AppRoutes, makeQueryClient } from "./App";
import { fakeApi } from "./test/fixtures";

function renderAt(path: string, fetchImpl: typeof fetch = fakeApi()) {
  vi.stubGlobal("fetch", vi.fn(fetchImpl));
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[path]}>
        <AppRoutes />
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

afterEach(() => {
  vi.unstubAllGlobals();
});

/** The URLs the app requested, from the stubbed fetch. */
function requestedUrls(): string[] {
  return vi.mocked(fetch).mock.calls.map(([input]) =>
    typeof input === "string" ? input : input instanceof URL ? input.href : input.url,
  );
}

describe("home page", () => {
  it("shows the hero, the stats and datasets grouped by organization", async () => {
    renderAt("/");
    expect(screen.getByRole("heading", { level: 1, name: "קטלוג המאגרים" })).toBeInTheDocument();
    expect(await screen.findByRole("link", { name: "מאגר טיסות" })).toHaveAttribute("href", "/dataset/flydata");
    expect(screen.getByRole("region", { name: "רשות שדות התעופה" })).toBeInTheDocument();
    expect(screen.getByText("מאגרים בקטלוג").previousSibling).toHaveTextContent("1");
    await waitFor(() => {
      expect(screen.getAllByText(/סונכרן מ-data.gov.il/).length).toBeGreaterThan(0);
    });
  });

  it("suggests datasets while typing and opens one with the keyboard", async () => {
    const user = userEvent.setup();
    renderAt("/");
    const box = screen.getByRole("combobox");
    await user.type(box, "טיס");
    const option = await screen.findByRole("option", { name: /מאגר טיסות/ });
    expect(option).toBeInTheDocument();
    await user.keyboard("{ArrowDown}{Enter}");
    expect(await screen.findByRole("tab", { name: "סקירה" })).toBeInTheDocument();
  });

  it("explains a server error and offers a retry", async () => {
    renderAt("/", fakeApi({ "/api/datasets": 500 }));
    expect(await screen.findByRole("alert")).toHaveTextContent("לא הצלחנו לטעון");
    expect(screen.getByRole("button", { name: "נסו שוב" })).toBeInTheDocument();
  });
});

describe("catalog page", () => {
  it("lists results with filters taken from the facets", async () => {
    const user = userEvent.setup();
    renderAt("/catalog?q=טיסות");
    expect(await screen.findByText('נמצאו 1 מאגרים עבור "טיסות"')).toBeInTheDocument();
    const org = await screen.findByRole("combobox", { name: "ארגון" });
    await screen.findByRole("option", { name: "רשות שדות התעופה (1)" });
    await user.selectOptions(org, "iaa");
    await user.selectOptions(screen.getByRole("combobox", { name: "מיון" }), "modified");
    await waitFor(() => {
      expect(requestedUrls().some((u) => u.includes("org=iaa") && u.includes("sort=modified"))).toBe(true);
    });
  });

  it("says so when nothing matches", async () => {
    renderAt("/catalog?q=zzz", fakeApi({ "/api/datasets": { items: [], total: 0, page: 1, size: 12 } }));
    expect(await screen.findByText(/לא נמצאו מאגרים/)).toBeInTheDocument();
  });
});

describe("dataset page", () => {
  it("shows the overview with the source link and files", async () => {
    renderAt("/dataset/flydata");
    expect(await screen.findByRole("heading", { level: 1, name: "מאגר טיסות" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "הדף ב-data.gov.il" })).toHaveAttribute(
      "href",
      "https://data.gov.il/dataset/flydata",
    );
    expect(screen.getByText("126.6 KB", { exact: false })).toBeInTheDocument();
  });

  it("shows the table's columns and searchable rows", async () => {
    const user = userEvent.setup();
    renderAt("/dataset/flydata");
    await user.click(await screen.findByRole("tab", { name: "טבלאות ונתונים" }));
    const table = await screen.findByRole("region", { name: "שורות הטבלה" });
    expect(within(table).getByText("W6")).toBeInTheDocument();
    // the column dictionary explains the source's codes and where they end up
    expect(screen.getAllByText("CHOPER").length).toBeGreaterThan(0);
    expect(screen.getByText("CHLOC1TH")).toBeInTheDocument();
    expect(screen.getAllByText("airline_code").length).toBeGreaterThan(0);
    expect(screen.getByText("מספר")).toBeInTheDocument();
    await user.type(screen.getByLabelText("חיפוש בשורות"), "LY");
    await waitFor(() => {
      expect(requestedUrls().some((u) => u.includes("q=LY"))).toBe(true);
    });
  });

  it("shows the flights board in English and Tel Aviv time", async () => {
    const user = userEvent.setup();
    renderAt("/dataset/flydata");
    await user.click(await screen.findByRole("tab", { name: "לוח טיסות" }));
    expect(await screen.findByText("LY 001")).toBeInTheDocument();
    expect(screen.getByText("NEW YORK")).toBeInTheDocument();
    expect(screen.getByText("10:00")).toBeInTheDocument(); // shown as stored, not shifted by the browser's time zone
    expect(screen.getByText("17/11/2026 10:12")).toBeInTheDocument(); // ingest time
    await user.selectOptions(screen.getByRole("combobox", { name: "כיוון" }), "arrival");
    await waitFor(() => {
      expect(requestedUrls().some((u) => u.includes("direction=arrival"))).toBe(true);
    });
  });

  it("shows the change history", async () => {
    const user = userEvent.setup();
    renderAt("/dataset/flydata");
    await user.click(await screen.findByRole("tab", { name: "היסטוריית שינויים" }));
    expect(await screen.findByText(/מבנה הטבלה "טיסות": 2 עמודות/)).toBeInTheDocument();
  });

  it("says when a dataset does not exist", async () => {
    renderAt("/dataset/missing");
    expect(await screen.findByRole("alert")).toHaveTextContent("הפריט המבוקש לא נמצא");
  });
});

describe("other pages and the API client", () => {
  it("renders the about and not-found pages", () => {
    renderAt("/about");
    expect(screen.getByRole("heading", { name: "על הקטלוג" })).toBeInTheDocument();
  });

  it("renders a not-found page for unknown paths", () => {
    renderAt("/nowhere");
    expect(screen.getByRole("heading", { name: "הדף לא נמצא" })).toBeInTheDocument();
  });

  it("builds query strings and raises ApiError on failures", async () => {
    const spy = vi.fn(fakeApi());
    vi.stubGlobal("fetch", spy);
    await api.datasets({ q: "a b", org: "", page: 2 });
    expect(requestedUrls()[0]).toBe("/api/datasets?q=a+b&page=2");
    await expect(getJson("/datasets/missing")).rejects.toBeInstanceOf(ApiError);
  });

  it("does not retry client errors", () => {
    const client = makeQueryClient();
    const retry = client.getDefaultOptions().queries?.retry as (n: number, e: unknown) => boolean;
    expect(retry(0, new ApiError(404, "x"))).toBe(false);
    expect(retry(0, new ApiError(503, "x"))).toBe(true);
    expect(retry(2, new Error("x"))).toBe(false);
  });
});
