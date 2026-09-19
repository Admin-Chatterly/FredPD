"use client"

/**
 * The last resort: this replaces the root layout, so it cannot use anything
 * from it and ships its own minimal styling.
 */
export default function GlobalError({
  error,
  reset,
}: {
  error: Error & { digest?: string }
  reset: () => void
}) {
  return (
    <html lang="sv">
      <body
        style={{
          margin: 0,
          minHeight: "100vh",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          background: "#0b0b0e",
          color: "#f4f4f5",
          fontFamily: "system-ui, sans-serif",
          padding: "1.5rem",
        }}
      >
        <div style={{ maxWidth: "32rem" }}>
          <h1 style={{ fontSize: "1.25rem", marginBottom: "0.5rem" }}>PD-span kunde inte starta</h1>
          <p style={{ color: "#a1a1aa", marginBottom: "1rem", lineHeight: 1.6 }}>
            Något gick fel utanför alla sidor. Att ladda om brukar räcka.
          </p>
          <pre
            style={{
              background: "#18181b",
              padding: "0.75rem",
              borderRadius: "0.375rem",
              fontSize: "0.75rem",
              overflowX: "auto",
              color: "#a1a1aa",
            }}
          >
            {process.env.NODE_ENV === "production" ? "Servern rapporterade ett fel." : error.message}
            {error.digest ? `\n\nReferens: ${error.digest}` : ""}
          </pre>
          <button
            onClick={reset}
            style={{
              marginTop: "1rem",
              padding: "0.5rem 1rem",
              borderRadius: "0.375rem",
              border: "1px solid #3f3f46",
              background: "#27272a",
              color: "inherit",
              cursor: "pointer",
            }}
          >
            Försök igen
          </button>
        </div>
      </body>
    </html>
  )
}
