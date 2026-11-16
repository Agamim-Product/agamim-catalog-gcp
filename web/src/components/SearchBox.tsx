import { useQuery } from "@tanstack/react-query";
import { useId, useState } from "react";
import { useNavigate } from "react-router-dom";
import { api } from "../api/client";
import { useDebounced } from "../lib/useDebounced";

/** Search field with suggestions (a combobox). Enter without a choice opens the catalog search. */
export function SearchBox({ initial = "" }: { initial?: string }) {
  const [text, setText] = useState(initial);
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(-1);
  const navigate = useNavigate();
  const listId = useId();
  const term = useDebounced(text.trim(), 200);

  const { data } = useQuery({
    queryKey: ["suggest", term],
    queryFn: ({ signal }) => api.suggest(term, signal),
    enabled: term.length >= 2,
    staleTime: 60_000,
  });
  const items = term.length >= 2 ? (data?.items ?? []) : [];
  const showList = open && items.length > 0;

  function go(name: string) {
    setOpen(false);
    void navigate(`/dataset/${encodeURIComponent(name)}`);
  }

  function submit(event: React.FormEvent) {
    event.preventDefault();
    const choice = active >= 0 ? items[active] : undefined;
    if (choice) {
      go(choice.name);
      return;
    }
    setOpen(false);
    void navigate(`/catalog?q=${encodeURIComponent(text.trim())}`);
  }

  function onKeyDown(event: React.KeyboardEvent<HTMLInputElement>) {
    if (!showList) return;
    if (event.key === "ArrowDown") {
      event.preventDefault();
      setActive((i) => (i + 1) % items.length);
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      setActive((i) => (i <= 0 ? items.length - 1 : i - 1));
    } else if (event.key === "Escape") {
      setOpen(false);
    }
  }

  return (
    <form className="search" role="search" onSubmit={submit}>
      <label htmlFor={`${listId}-input`} className="visually-hidden">
        חיפוש מאגר מידע
      </label>
      <input
        id={`${listId}-input`}
        type="search"
        value={text}
        placeholder="חפשו מאגר, ארגון, תגית או שם עמודה"
        autoComplete="off"
        role="combobox"
        aria-expanded={showList}
        aria-controls={`${listId}-list`}
        aria-autocomplete="list"
        aria-activedescendant={showList && active >= 0 ? `${listId}-opt-${active}` : undefined}
        onChange={(e) => {
          setText(e.target.value);
          setOpen(true);
          setActive(-1);
        }}
        onFocus={() => {
          setOpen(true);
        }}
        onBlur={() => {
          window.setTimeout(() => {
            setOpen(false);
          }, 150);
        }}
        onKeyDown={onKeyDown}
      />
      <button type="submit" className="btn btn-primary">
        חיפוש
      </button>
      {showList ? (
        <ul id={`${listId}-list`} role="listbox" className="suggest" aria-label="הצעות">
          {items.map((item, i) => (
            <li
              key={item.name}
              id={`${listId}-opt-${i}`}
              // eslint-disable-next-line jsx-a11y/no-noninteractive-element-to-interactive-role -- options of the combobox listbox
              role="option"
              aria-selected={i === active}
              className={i === active ? "active" : undefined}
              onMouseDown={(e) => {
                e.preventDefault();
                go(item.name);
              }}
            >
              <span className="suggest-title">{item.title}</span>
              {item.organization ? <span className="suggest-org">{item.organization}</span> : null}
            </li>
          ))}
        </ul>
      ) : null}
    </form>
  );
}
