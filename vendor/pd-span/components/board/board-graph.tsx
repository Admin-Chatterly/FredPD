"use client"

import { useMemo } from "react"
import { useRouter } from "next/navigation"
import {
  Background,
  Controls,
  MiniMap,
  ReactFlow,
  useEdgesState,
  useNodesState,
  type Edge,
} from "@xyflow/react"
import type { OrganizationNode, PersonNode } from "@/components/board/board-nodes"
import { boardNodeTypes } from "@/components/board/board-nodes"
import { layoutGraph, type LayoutLink, type LayoutNode } from "@/lib/board-layout"
import type { BoardGraph } from "@/lib/data/board"
import { isUnidentified, personLabel, personSecondary, truncate } from "@/lib/format"

import "@xyflow/react/dist/style.css"

type BoardNode = PersonNode | OrganizationNode

const MEMBERSHIP_COLOUR = "oklch(0.85 0.12 75)"
const ASSOCIATE_COLOUR = "oklch(0.7 0.14 190)"


export function BoardGraphView({ graph }: { graph: BoardGraph }) {
  const router = useRouter()

  const { initialNodes, initialEdges } = useMemo(() => {
    const layoutNodes: LayoutNode[] = [
      ...graph.people.map((p) => ({ id: `person:${p.id}` })),
      ...graph.organizations.map((o) => ({ id: `organization:${o.id}` })),
    ]
    const layoutLinks: LayoutLink[] = [
      ...graph.memberships.map((m) => ({
        source: `person:${m.personId}`,
        target: `organization:${m.organizationId}`,
      })),
      ...graph.associates.map((a) => ({
        source: `person:${a.personId}`,
        target: `person:${a.associateId}`,
      })),
    ]
    const positions = layoutGraph(layoutNodes, layoutLinks)

    const personNodes: BoardNode[] = graph.people.map((person) => {
      const secondary = personSecondary(person)
      return {
        id: `person:${person.id}`,
        type: "person",
        position: positions.get(`person:${person.id}`) ?? { x: 0, y: 0 },
        data: {
          label: personLabel(person),
          sublabel: secondary ? truncate(secondary, 40) : null,
          status: person.status,
          unidentified: isUnidentified(person),
        },
      }
    })

    const organizationNodes: BoardNode[] = graph.organizations.map((organization) => ({
      id: `organization:${organization.id}`,
      type: "organization",
      position: positions.get(`organization:${organization.id}`) ?? { x: 0, y: 0 },
      data: {
        label: organization.name,
        type: organization.type,
        status: organization.status,
      },
    }))

    const membershipEdges: Edge[] = graph.memberships.map((m) => ({
      id: `membership:${m.personId}:${m.organizationId}`,
      source: `person:${m.personId}`,
      target: `organization:${m.organizationId}`,
      label: m.role ?? undefined,
      style: {
        stroke: MEMBERSHIP_COLOUR,
        strokeWidth: m.isConfirmed ? 2 : 1.5,
        strokeDasharray: m.isConfirmed ? undefined : "6 4",
      },
      labelStyle: { fill: "currentColor", fontSize: 11 },
      labelBgStyle: { fill: "oklch(0.17 0.005 260)" },
    }))

    const associateEdges: Edge[] = graph.associates.map((a) => ({
      id: `associate:${a.personId}:${a.associateId}`,
      source: `person:${a.personId}`,
      target: `person:${a.associateId}`,
      label: a.relationship ?? undefined,
      style: {
        stroke: ASSOCIATE_COLOUR,
        strokeWidth: a.isConfirmed ? 2 : 1.5,
        strokeDasharray: a.isConfirmed ? undefined : "6 4",
      },
      labelStyle: { fill: "currentColor", fontSize: 11 },
      labelBgStyle: { fill: "oklch(0.17 0.005 260)" },
    }))

    return {
      initialNodes: [...organizationNodes, ...personNodes],
      initialEdges: [...membershipEdges, ...associateEdges],
    }
  }, [graph])

  // The page remounts this component when the scope changes, so the initial
  // values are always the current graph and the officer keeps any nodes they
  // dragged while the scope stays put.
  const [nodes, , onNodesChange] = useNodesState<BoardNode>(initialNodes)
  const [edges, , onEdgesChange] = useEdgesState<Edge>(initialEdges)

  return (
    <div className="h-[70vh] overflow-hidden rounded-lg border border-border">
      <ReactFlow
        nodes={nodes}
        edges={edges}
        onNodesChange={onNodesChange}
        onEdgesChange={onEdgesChange}
        nodeTypes={boardNodeTypes}
        onNodeClick={(_event, node) => {
          const [kind, id] = node.id.split(":")
          router.push(kind === "person" ? `/people/${id}` : `/organizations/${id}`)
        }}
        fitView
        minZoom={0.1}
        maxZoom={2}
        proOptions={{ hideAttribution: false }}
        nodesConnectable={false}
        edgesFocusable={false}
      >
        <Background gap={24} />
        <Controls showInteractive={false} />
        <MiniMap pannable zoomable className="!bg-card" />
      </ReactFlow>
    </div>
  )
}
