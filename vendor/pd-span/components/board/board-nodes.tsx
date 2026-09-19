"use client"

import { Handle, Position, type Node, type NodeProps } from "@xyflow/react"
import {
  ORGANIZATION_TYPE_LABELS,
  PERSON_STATUS_LABELS,
  PERSON_STATUSES,
  type OrganizationType,
  type PersonStatus,
} from "@/lib/constants"
import { cn } from "@/lib/utils"

/**
 * Both handles sit invisibly at the centre of the node. The layout is
 * force-directed, so edges arrive from every angle and fixed side handles would
 * leave them attaching to the wrong edge of the box.
 */
function CentreHandles() {
  return (
    <>
      <Handle
        type="target"
        position={Position.Top}
        className="!left-1/2 !top-1/2 !h-px !min-h-0 !w-px !min-w-0 !-translate-x-1/2 !-translate-y-1/2 !border-0 !bg-transparent"
      />
      <Handle
        type="source"
        position={Position.Bottom}
        className="!left-1/2 !top-1/2 !h-px !min-h-0 !w-px !min-w-0 !-translate-x-1/2 !-translate-y-1/2 !border-0 !bg-transparent"
      />
    </>
  )
}

/** Node borders carry the status, so a warrant is visible without reading. */
const PERSON_NODE_STYLES: Record<PersonStatus, string> = {
  unknown: "border-zinc-500/60 bg-zinc-500/10",
  poi: "border-sky-500/70 bg-sky-500/10",
  active_investigation: "border-amber-500/70 bg-amber-500/10",
  warrant: "border-red-500 bg-red-500/20",
  cleared: "border-emerald-500/70 bg-emerald-500/10",
  incarcerated: "border-violet-500/70 bg-violet-500/10",
  deceased: "border-zinc-700 bg-zinc-800/60",
}

export type PersonNodeData = {
  label: string
  sublabel: string | null
  status: string
  unidentified: boolean
}

export type PersonNode = Node<PersonNodeData, "person">

export function PersonBoardNode({ data, selected }: NodeProps<PersonNode>) {
  const status = (PERSON_STATUSES as readonly string[]).includes(data.status)
    ? (data.status as PersonStatus)
    : "unknown"

  return (
    <div
      className={cn(
        "w-44 rounded-lg border-2 px-3 py-2 text-center shadow-sm transition-shadow",
        PERSON_NODE_STYLES[status],
        data.unidentified && "border-dashed",
        selected && "ring-2 ring-primary ring-offset-2 ring-offset-background"
      )}
      title={`${data.label} · ${PERSON_STATUS_LABELS[status]}`}
    >
      <CentreHandles />
      <p className="truncate text-sm font-medium text-foreground">{data.label}</p>
      {data.sublabel ? (
        <p className="truncate text-[11px] text-muted-foreground">{data.sublabel}</p>
      ) : null}
    </div>
  )
}

export type OrganizationNodeData = {
  label: string
  type: string | null
  status: string
}

export type OrganizationNode = Node<OrganizationNodeData, "organization">

export function OrganizationBoardNode({ data, selected }: NodeProps<OrganizationNode>) {
  const typeLabel = data.type
    ? (ORGANIZATION_TYPE_LABELS[data.type as OrganizationType] ?? data.type)
    : null

  return (
    <div
      className={cn(
        "w-48 rounded-sm border-2 border-primary/70 bg-primary/15 px-3 py-2 text-center shadow-sm",
        data.status === "disbanded" && "border-zinc-700 bg-zinc-800/60 opacity-70",
        selected && "ring-2 ring-primary ring-offset-2 ring-offset-background"
      )}
      title={data.label}
    >
      <CentreHandles />
      <p className="truncate text-sm font-semibold text-foreground">{data.label}</p>
      {typeLabel ? (
        <p className="truncate text-[11px] uppercase tracking-wide text-muted-foreground">
          {typeLabel}
        </p>
      ) : null}
    </div>
  )
}

export const boardNodeTypes = {
  person: PersonBoardNode,
  organization: OrganizationBoardNode,
}
