import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { HashRouter, Route, Routes } from "react-router-dom";
import { ApiError } from "./api/client";
import { Layout } from "./components/Layout";
import { AboutPage, NotFoundPage } from "./pages/AboutPage";
import { CatalogPage } from "./pages/CatalogPage";
import { DatasetPage } from "./pages/DatasetPage";
import { HomePage } from "./pages/HomePage";

export function makeQueryClient(): QueryClient {
  return new QueryClient({
    defaultOptions: {
      queries: {
        staleTime: 60_000,
        retry: (count, error) => !(error instanceof ApiError && error.status < 500) && count < 2,
        refetchOnWindowFocus: false,
      },
    },
  });
}

export function AppRoutes() {
  return (
    <Routes>
      <Route element={<Layout />}>
        <Route index element={<HomePage />} />
        <Route path="catalog" element={<CatalogPage />} />
        <Route path="dataset/:name" element={<DatasetPage />} />
        <Route path="about" element={<AboutPage />} />
        <Route path="*" element={<NotFoundPage />} />
      </Route>
    </Routes>
  );
}

// Hash routes (/#/catalog) let the static bucket serve every page from index.html.
export function App({ client = makeQueryClient() }: { client?: QueryClient }) {
  return (
    <QueryClientProvider client={client}>
      <HashRouter>
        <AppRoutes />
      </HashRouter>
    </QueryClientProvider>
  );
}
