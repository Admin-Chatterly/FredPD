export function BoardLegend() {
  return (
    <div className="flex flex-wrap items-center gap-x-5 gap-y-2 text-xs text-muted-foreground">
      <span className="flex items-center gap-1.5">
        <span className="inline-block h-3 w-5 rounded-sm border-2 border-primary/70 bg-primary/15" />
        Organisation
      </span>
      <span className="flex items-center gap-1.5">
        <span className="inline-block h-3 w-5 rounded border-2 border-sky-500/70 bg-sky-500/10" />
        Person
      </span>
      <span className="flex items-center gap-1.5">
        <span className="inline-block h-3 w-5 rounded border-2 border-dashed border-zinc-500/60" />
        Inget känt namn
      </span>
      <span className="flex items-center gap-1.5">
        <svg width="28" height="8" aria-hidden="true">
          <line x1="0" y1="4" x2="28" y2="4" stroke="oklch(0.85 0.12 75)" strokeWidth="2" />
        </svg>
        Medlemskap
      </span>
      <span className="flex items-center gap-1.5">
        <svg width="28" height="8" aria-hidden="true">
          <line x1="0" y1="4" x2="28" y2="4" stroke="oklch(0.7 0.14 190)" strokeWidth="2" />
        </svg>
        Kontakt
      </span>
      <span className="flex items-center gap-1.5">
        <svg width="28" height="8" aria-hidden="true">
          <line
            x1="0"
            y1="4"
            x2="28"
            y2="4"
            stroke="currentColor"
            strokeWidth="2"
            strokeDasharray="6 4"
          />
        </svg>
        Misstänkt, ej bekräftat
      </span>
    </div>
  )
}
