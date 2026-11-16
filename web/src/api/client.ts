import type {
  Dataset,
  Facets,
  FlightVersion,
  FlightsPage,
  HistoryItem,
  Paged,
  RowsPage,
  Status,
  Suggestion,
} from "./types";

export class ApiError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

type Params = Record<string, string | number | undefined>;

function query(params: Params): string {
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined && value !== "") search.set(key, String(value));
  }
  const text = search.toString();
  return text ? `?${text}` : "";
}

export async function getJson<T>(path: string, params: Params = {}, signal?: AbortSignal): Promise<T> {
  const response = await fetch(`/api${path}${query(params)}`, {
    headers: { Accept: "application/json" },
    ...(signal ? { signal } : {}),
  });
  if (!response.ok) {
    throw new ApiError(response.status, `הבקשה נכשלה (${response.status})`);
  }
  return (await response.json()) as T;
}

export interface DatasetQuery {
  q?: string;
  org?: string;
  tag?: string;
  format?: string;
  sort?: "title" | "modified";
  page?: number;
  size?: number;
}

const enc = encodeURIComponent;

export const api = {
  status: (signal?: AbortSignal) => getJson<Status>("/status", {}, signal),
  datasets: (q: DatasetQuery, signal?: AbortSignal) => getJson<Paged<Dataset>>("/datasets", { ...q }, signal),
  dataset: (name: string, signal?: AbortSignal) => getJson<Dataset>(`/datasets/${enc(name)}`, {}, signal),
  history: (name: string, signal?: AbortSignal) =>
    getJson<{ items: HistoryItem[] }>(`/datasets/${enc(name)}/history`, {}, signal),
  facets: (signal?: AbortSignal) => getJson<Facets>("/facets", {}, signal),
  suggest: (q: string, signal?: AbortSignal) => getJson<{ items: Suggestion[] }>("/suggest", { q }, signal),
  rows: (resourceId: string, p: { q?: string; page?: number; size?: number }, signal?: AbortSignal) =>
    getJson<RowsPage>(`/resources/${enc(resourceId)}/rows`, { ...p }, signal),
  flights: (
    p: { q?: string; direction?: string; status?: string; page?: number; size?: number },
    signal?: AbortSignal,
  ) => getJson<FlightsPage>("/flights", { ...p }, signal),
  flightHistory: (key: string, signal?: AbortSignal) =>
    getJson<{ items: FlightVersion[] }>(`/flights/${enc(key)}/history`, {}, signal),
};
