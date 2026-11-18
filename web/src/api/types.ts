// Shapes returned by the catalog API (backend/src/catalog/api). Times are ISO-8601 strings.

export interface Column {
  name: string;
  type: string;
  position: number;
}

export interface Resource {
  resource_id: string;
  name: string | null;
  description: string | null;
  format: string | null;
  download_url: string | null;
  size_bytes: number | null;
  is_queryable: boolean;
  update_frequency: string | null;
  data_modified_at: string | null;
  columns: Column[] | null;
  row_count: number | null;
  has_full_rows: boolean | null;
  copied_at: string | null;
  schema_changed_at: string | null;
}

export interface Organization {
  id: string | null;
  name: string | null;
  title: string | null;
  image_url: string | null;
}

export interface Dataset {
  dataset_id: string;
  name: string;
  title: string;
  description: string | null;
  license: string | null;
  author: string | null;
  maintainer: string | null;
  update_frequency: string | null;
  tags: string[];
  source_created_at: string | null;
  source_modified_at: string | null;
  source_url: string;
  catalog_changed_at: string | null;
  organization: Organization;
  resources: Resource[];
}

export interface Paged<T> {
  items: T[];
  total: number;
  page: number;
  size: number;
}

export interface FacetValue {
  value: string;
  label: string;
  count: number;
}

export interface Facets {
  organizations: FacetValue[];
  tags: FacetValue[];
  formats: FacetValue[];
}

export interface Suggestion {
  name: string;
  title: string;
  organization: string | null;
}

export interface IngestionRun {
  run_id: string;
  started_at: string | null;
  finished_at: string | null;
  transformed_at: string | null;
  status: string | null;
  datasets: number | null;
  rows_copied: number | null;
  tables_failed: number | null;
}

export interface Status {
  last_run: IngestionRun | null;
  recent_runs: IngestionRun[];
  datasets: number;
  flights: number;
}

export interface HistoryItem {
  kind: "dataset" | "table_structure";
  id: string;
  label: string | null;
  valid_from: string;
  valid_to: string | null;
  is_current: boolean;
  snapshot: string;
}

export type TableRow = Record<string, unknown>;

export interface RowsPage extends Paged<TableRow> {
  columns: Column[];
}

export interface Flight {
  flight_key: string;
  airline_code: string;
  flight_number: string;
  airline_name: string | null;
  direction: "arrival" | "departure";
  scheduled_at: string;
  estimated_at: string | null;
  airport_code: string | null;
  city_en: string | null;
  country_en: string | null;
  terminal: number | null;
  checkin_counters: string | null;
  checkin_zone: string | null;
  status_en: string | null;
  /** Tel Aviv time, no time zone suffix (like scheduled_at and estimated_at). */
  ingested_at: string;
}

export interface FlightsPage extends Paged<Flight> {
  statuses: FacetValue[];
}
