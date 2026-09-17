import Link from "next/link"
import { Badge } from "@/components/ui/badge"
import {
  CASE_STATUSES,
  CASE_STATUS_LABELS,
  CASE_STATUS_STYLES,
  CONFIDENCES,
  CONFIDENCE_LABELS,
  CONFIDENCE_STYLES,
  ORGANIZATION_STATUSES,
  ORGANIZATION_STATUS_LABELS,
  ORGANIZATION_STATUS_STYLES,
  ORGANIZATION_TYPE_LABELS,
  ORGANIZATION_TYPES,
  PERSON_STATUSES,
  PERSON_STATUS_LABELS,
  PERSON_STATUS_STYLES,
  type CaseStatus,
  type Confidence,
  type OrganizationStatus,
  type OrganizationType,
  type PersonStatus,
} from "@/lib/constants"
import { cn } from "@/lib/utils"

function pick<T extends string>(values: readonly T[], value: string | null | undefined, fallback: T): T {
  return (values as readonly string[]).includes(value ?? "") ? (value as T) : fallback
}

export function PersonStatusBadge({ status, className }: { status: string | null | undefined; className?: string }) {
  const s: PersonStatus = pick(PERSON_STATUSES, status, "unknown")
  return (
    <Badge variant="outline" className={cn(PERSON_STATUS_STYLES[s], className)}>
      {PERSON_STATUS_LABELS[s]}
    </Badge>
  )
}

export function UnknownBadge({ className }: { className?: string }) {
  return (
    <Badge variant="outline" className={cn("border-dashed border-amber-500/50 text-amber-300", className)}>
      Oidentifierad
    </Badge>
  )
}

export function OrganizationStatusBadge({ status, className }: { status: string | null | undefined; className?: string }) {
  const s: OrganizationStatus = pick(ORGANIZATION_STATUSES, status, "active")
  return (
    <Badge variant="outline" className={cn(ORGANIZATION_STATUS_STYLES[s], className)}>
      {ORGANIZATION_STATUS_LABELS[s]}
    </Badge>
  )
}

export function OrganizationTypeBadge({ type, className }: { type: string | null | undefined; className?: string }) {
  if (!type) return null
  const t: OrganizationType = pick(ORGANIZATION_TYPES, type, "other")
  return (
    <Badge variant="secondary" className={className}>
      {ORGANIZATION_TYPE_LABELS[t]}
    </Badge>
  )
}

export function ConfidenceBadge({ confidence, className }: { confidence: string | null | undefined; className?: string }) {
  const c: Confidence = pick(CONFIDENCES, confidence, "medium")
  return (
    <Badge variant="outline" className={cn(CONFIDENCE_STYLES[c], className)}>
      Tillförlitlighet: {CONFIDENCE_LABELS[c]}
    </Badge>
  )
}

export function CaseStatusBadge({ status, className }: { status: string | null | undefined; className?: string }) {
  const s: CaseStatus = pick(CASE_STATUSES, status, "open")
  return (
    <Badge variant="outline" className={cn(CASE_STATUS_STYLES[s], className)}>
      {CASE_STATUS_LABELS[s]}
    </Badge>
  )
}

export function MembershipBadge({ isConfirmed, className }: { isConfirmed: boolean; className?: string }) {
  return isConfirmed ? (
    <Badge variant="outline" className={cn("border-emerald-500/40 bg-emerald-500/15 text-emerald-300", className)}>
      Bekräftad
    </Badge>
  ) : (
    <Badge variant="outline" className={cn("border-dashed border-zinc-500/50 text-zinc-400", className)}>
      Misstänkt
    </Badge>
  )
}

/**
 * Taggar är filtret som går tvärs igenom allt, så var och en av dem är en väg in
 * till underrättelsesidan filtrerad på just den taggen.
 */
export function TagBadge({
  tag,
  className,
  linked = true,
}: {
  tag: string
  className?: string
  linked?: boolean
}) {
  const badge = (
    <Badge variant="secondary" className={cn("font-mono text-xs", className)}>
      #{tag}
    </Badge>
  )
  if (!linked) return badge
  return (
    <Link href={`/intel?tag=${encodeURIComponent(tag)}`} title={`Visa uppgifter taggade ${tag}`}>
      {badge}
    </Link>
  )
}
