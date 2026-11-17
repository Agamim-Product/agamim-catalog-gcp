import type { Dataset, FlightsPage, RowsPage, Status } from "../api/types";

export const dataset: Dataset = {
  dataset_id: "d1",
  name: "flydata",
  title: "מאגר טיסות",
  description: "מאגר הטיסות מתעדכן כל 15 דקות",
  license: "Other (Open)",
  author: null,
  maintainer: null,
  update_frequency: "Times in day",
  tags: ["תעופה"],
  source_created_at: "2017-08-06T10:53:26Z",
  source_modified_at: "2026-11-17T12:30:00Z",
  source_url: "https://data.gov.il/dataset/flydata",
  catalog_changed_at: "2026-11-17T12:47:00Z",
  organization: { id: "o1", name: "iaa", title: "רשות שדות התעופה", image_url: null },
  resources: [
    {
      resource_id: "r1",
      name: "טיסות",
      description: null,
      format: "CSV",
      download_url: "https://data.gov.il/x.csv",
      size_bytes: 129611,
      is_queryable: true,
      update_frequency: null,
      data_modified_at: "2026-11-17T12:30:00Z",
      columns: [
        { name: "CHOPER", type: "text", position: 1 },
        { name: "CHTERM", type: "numeric", position: 2 },
      ],
      row_count: 2,
      has_full_rows: true,
      copied_at: "2026-11-17T12:47:00Z",
      schema_changed_at: "2026-11-17T12:00:00Z",
    },
    {
      resource_id: "r2",
      name: "מסמך",
      description: null,
      format: "PDF",
      download_url: null,
      size_bytes: null,
      is_queryable: false,
      update_frequency: null,
      data_modified_at: null,
      columns: null,
      row_count: null,
      has_full_rows: null,
      copied_at: null,
      schema_changed_at: null,
    },
  ],
};

export const status: Status = {
  last_run: {
    run_id: "20261117124722",
    started_at: "2026-11-17T12:47:22Z",
    finished_at: "2026-11-17T12:48:20Z",
    transformed_at: "2026-11-17T12:48:20Z",
    status: "succeeded",
    datasets: 1,
    rows_copied: 2257,
    tables_failed: 0,
  },
  recent_runs: [],
  datasets: 1,
  flights: 2,
};

export const rows: RowsPage = {
  items: [
    { _id: 1, CHOPER: "LY", CHTERM: 3 },
    { _id: 2, CHOPER: "W6", CHTERM: null },
  ],
  total: 2,
  page: 1,
  size: 25,
  columns: dataset.resources[0]?.columns ?? [],
};

export const flights: FlightsPage = {
  items: [
    {
      flight_key: "LY-001-arrival-20261117T1000",
      airline_code: "LY",
      flight_number: "001",
      airline_name: "EL AL",
      direction: "arrival",
      scheduled_at: "2026-11-17T08:00:00Z",
      estimated_at: "2026-11-17T08:10:00Z",
      airport_code: "JFK",
      city_en: "NEW YORK",
      city_he: "ניו יורק",
      country_he: "ארצות הברית",
      terminal: 3,
      checkin_counters: null,
      status_en: "LANDED",
      status_he: "נחתה",
      changed_at: "2026-11-17T08:12:00Z",
    },
  ],
  total: 1,
  page: 1,
  size: 30,
  statuses: [{ value: "LANDED", label: "נחתה", count: 1 }],
};

/** A fetch stand-in that answers the app's API calls from the fixtures above. */
export function fakeApi(overrides: Record<string, unknown> = {}): typeof fetch {
  const routes: [RegExp, unknown][] = [
    [/^\/api\/status/, status],
    [/^\/api\/facets/, {
      organizations: [{ value: "iaa", label: "רשות שדות התעופה", count: 1 }],
      tags: [{ value: "תעופה", label: "תעופה", count: 1 }],
      formats: [{ value: "CSV", label: "CSV", count: 1 }],
    }],
    [/^\/api\/suggest/, { items: [{ name: "flydata", title: "מאגר טיסות", organization: "רשות שדות התעופה" }] }],
    [/^\/api\/datasets\/flydata\/history/, { items: [
      { kind: "dataset", id: "d1", label: "מאגר טיסות", valid_from: "2026-11-17T12:00:00Z", valid_to: null, is_current: true, snapshot: "{}" },
      { kind: "table_structure", id: "r1", label: "טיסות", valid_from: "2026-11-17T11:00:00Z", valid_to: null, is_current: true, snapshot: '{"columns":[1,2]}' },
    ] }],
    [/^\/api\/datasets\/missing/, 404],
    [/^\/api\/datasets\/flydata/, dataset],
    [/^\/api\/datasets/, { items: [dataset], total: 1, page: 1, size: 12 }],
    [/^\/api\/resources\/r1\/rows/, rows],
    [/^\/api\/flights\/.+\/history/, { items: [
      { status_en: "LANDED", status_he: "נחתה", estimated_at: "2026-11-17T08:10:00Z", terminal: 3, checkin_counters: null, valid_from: "2026-11-17T08:12:00Z", valid_to: null, is_current: true },
    ] }],
    [/^\/api\/flights/, flights],
  ];
  return ((input: RequestInfo | URL) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.pathname + input.search : input.url;
    for (const [key, body] of Object.entries(overrides)) {
      if (url.startsWith(key)) return Promise.resolve(jsonResponse(body));
    }
    const hit = routes.find(([pattern]) => pattern.test(url));
    if (!hit) return Promise.resolve(new Response("not found", { status: 404 }));
    return Promise.resolve(jsonResponse(hit[1]));
  });
}

function jsonResponse(body: unknown): Response {
  if (typeof body === "number") return new Response("error", { status: body });
  return new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } });
}
