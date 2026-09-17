/**
 * Supabase rapporterar varje misslyckad inloggning med en maskinläsbar kod. Att
 * klumpa ihop dem till "fel lösenord" döljer de orsaker som faktiskt uppstår vid
 * uppsättningen: ett konto som aldrig bekräftades, en felstavad projektadress,
 * en nyckel från ett annat projekt, eller att e-postinloggning är avstängd.
 */
export type SignInErrorLike = {
  name?: string
  message?: string
  code?: string
  status?: number
}

export function describeSignInError(error: SignInErrorLike): string {
  const message = error.message ?? ""

  switch (error.code) {
    case "invalid_credentials":
      return "Fel e-postadress eller lösenord. Om kollegan inte är upplagd ännu, skapa kontot i Supabase under Authentication → Users."
    case "email_not_confirmed":
      return "Kontot finns men e-postadressen är inte bekräftad. Öppna Authentication → Users i Supabase och bekräfta det, eller ta bort det och lägg upp det igen med “Auto Confirm User” ikryssad."
    case "user_not_found":
      return "Inget konto med den e-postadressen. Lägg upp kollegan i Supabase under Authentication → Users."
    case "user_banned":
      return "Kontot är avstängt i Supabase."
    case "signup_disabled":
    case "email_provider_disabled":
    case "provider_disabled":
      return "Inloggning med e-post är avstängd i det här Supabase-projektet. Slå på Email under Authentication → Sign In / Providers."
    case "over_request_rate_limit":
      return "För många försök. Vänta en minut och försök igen."
    case "validation_failed":
      return `Supabase avvisade begäran: ${message}`
  }

  // Utan HTTP-status nådde begäran aldrig fram till projektet.
  if (error.name === "AuthRetryableFetchError" || error.status === undefined || error.status === 0) {
    return "Kunde inte nå Supabase. Kontrollera att projektadressen är https://<ref>.supabase.co och att projektet inte är pausat."
  }

  if (error.status === 401 || /invalid api key|no api key/i.test(message)) {
    return "Supabase avvisade API-nyckeln. Kontrollera att anon-nyckeln hör till det här projektet."
  }

  return message ? `Inloggningen misslyckades: ${message}` : "Inloggningen misslyckades."
}
