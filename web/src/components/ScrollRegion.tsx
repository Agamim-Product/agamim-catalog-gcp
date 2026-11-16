/** A horizontally scrollable region (wide tables). It is focusable so keyboard users can scroll it (WCAG 2.1.1). */
export function ScrollRegion({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    // eslint-disable-next-line jsx-a11y/no-noninteractive-tabindex -- scrollable regions must be keyboard-focusable
    <div className="table-scroll" role="region" aria-label={label} tabIndex={0}>
      {children}
    </div>
  );
}
