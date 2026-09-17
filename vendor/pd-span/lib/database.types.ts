/**
 * Hand-written to match supabase/migrations/0001_init.sql, in the shape the
 * Supabase CLI generates. Regenerate from a real database with `pnpm types:gen`
 * once SUPABASE_DB_URL is available; view columns come back nullable there, so
 * the app only reads views through the mappers in lib/data.
 */
export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  public: {
    Tables: {
      associates: {
        Row: {
          associate_id: string
          created_at: string
          is_confirmed: boolean
          person_id: string
          relationship: string | null
          url?: string | null
        }
        Insert: {
          associate_id: string
          created_at?: string
          is_confirmed?: boolean
          person_id: string
          relationship?: string | null
        }
        Update: {
          associate_id?: string
          created_at?: string
          is_confirmed?: boolean
          person_id?: string
          relationship?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "associates_associate_id_fkey"
            columns: ["associate_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "associates_person_id_fkey"
            columns: ["person_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
        ]
      }
      case_links: {
        Row: {
          case_id: string
          created_at: string
          id: string
          organization_id: string | null
          person_id: string | null
          role: string | null
        }
        Insert: {
          case_id: string
          created_at?: string
          id?: string
          organization_id?: string | null
          person_id?: string | null
          role?: string | null
        }
        Update: {
          case_id?: string
          created_at?: string
          id?: string
          organization_id?: string | null
          person_id?: string | null
          role?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "case_links_case_id_fkey"
            columns: ["case_id"]
            isOneToOne: false
            referencedRelation: "cases"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "case_links_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "case_links_person_id_fkey"
            columns: ["person_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
        ]
      }
      cases: {
        Row: {
          created_at: string
          created_by: string | null
          description: string | null
          id: string
          status: string
          title: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          description?: string | null
          id?: string
          status?: string
          title: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          description?: string | null
          id?: string
          status?: string
          title?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "cases_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      evidence: {
        Row: {
          caption: string | null
          case_id: string | null
          created_at: string
          created_by: string | null
          id: string
          organization_id: string | null
          person_id: string | null
          storage_path: string | null
          url: string | null
        }
        Insert: {
          caption?: string | null
          case_id?: string | null
          created_at?: string
          created_by?: string | null
          id?: string
          organization_id?: string | null
          person_id?: string | null
          storage_path?: string | null
          url?: string | null
        }
        Update: {
          caption?: string | null
          case_id?: string | null
          created_at?: string
          created_by?: string | null
          id?: string
          organization_id?: string | null
          person_id?: string | null
          storage_path?: string
        }
        Relationships: [
          {
            foreignKeyName: "evidence_case_id_fkey"
            columns: ["case_id"]
            isOneToOne: false
            referencedRelation: "cases"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "evidence_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "evidence_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "evidence_person_id_fkey"
            columns: ["person_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
        ]
      }
      memberships: {
        Row: {
          created_at: string
          is_confirmed: boolean
          organization_id: string
          person_id: string
          role: string | null
        }
        Insert: {
          created_at?: string
          is_confirmed?: boolean
          organization_id: string
          person_id: string
          role?: string | null
        }
        Update: {
          created_at?: string
          is_confirmed?: boolean
          organization_id?: string
          person_id?: string
          role?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "memberships_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "memberships_person_id_fkey"
            columns: ["person_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
        ]
      }
      notes: {
        Row: {
          body: string
          case_id: string | null
          confidence: string
          created_at: string
          created_by: string | null
          id: string
          organization_id: string | null
          person_id: string | null
          source: string | null
          tags: string[]
          updated_at: string
        }
        Insert: {
          body: string
          case_id?: string | null
          confidence?: string
          created_at?: string
          created_by?: string | null
          id?: string
          organization_id?: string | null
          person_id?: string | null
          source?: string | null
          tags?: string[]
          updated_at?: string
        }
        Update: {
          body?: string
          case_id?: string | null
          confidence?: string
          created_at?: string
          created_by?: string | null
          id?: string
          organization_id?: string | null
          person_id?: string | null
          source?: string | null
          tags?: string[]
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "notes_case_id_fkey"
            columns: ["case_id"]
            isOneToOne: false
            referencedRelation: "cases"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notes_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notes_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notes_person_id_fkey"
            columns: ["person_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
        ]
      }
      organizations: {
        Row: {
          created_at: string
          created_by: string | null
          id: string
          name: string
          notes: string | null
          search_text: string | null
          status: string
          territory: string | null
          type: string | null
          updated_at: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          id?: string
          name: string
          notes?: string | null
          status?: string
          territory?: string | null
          type?: string | null
          updated_at?: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          id?: string
          name?: string
          notes?: string | null
          status?: string
          territory?: string | null
          type?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "organizations_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      people: {
        Row: {
          alias: string | null
          created_at: string
          created_by: string | null
          description: string | null
          id: string
          name: string | null
          photo_path: string | null
          search_text: string | null
          status: string
          updated_at: string
        }
        Insert: {
          alias?: string | null
          created_at?: string
          created_by?: string | null
          description?: string | null
          id?: string
          name?: string | null
          photo_path?: string | null
          status?: string
          updated_at?: string
        }
        Update: {
          alias?: string | null
          created_at?: string
          created_by?: string | null
          description?: string | null
          id?: string
          name?: string | null
          photo_path?: string | null
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "people_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      profiles: {
        Row: {
          callsign: string | null
          created_at: string
          id: string
        }
        Insert: {
          callsign?: string | null
          created_at?: string
          id: string
        }
        Update: {
          callsign?: string | null
          created_at?: string
          id?: string
        }
        Relationships: []
      }
      vehicles: {
        Row: {
          color: string | null
          created_at: string
          created_by: string | null
          id: string
          model: string | null
          notes: string | null
          person_id: string | null
          plate: string | null
          search_text: string | null
          updated_at: string
        }
        Insert: {
          color?: string | null
          created_at?: string
          created_by?: string | null
          id?: string
          model?: string | null
          notes?: string | null
          person_id?: string | null
          plate?: string | null
          updated_at?: string
        }
        Update: {
          color?: string | null
          created_at?: string
          created_by?: string | null
          id?: string
          model?: string | null
          notes?: string | null
          person_id?: string | null
          plate?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "vehicles_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vehicles_person_id_fkey"
            columns: ["person_id"]
            isOneToOne: false
            referencedRelation: "people"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      cases_overview: {
        Row: {
          created_at: string | null
          created_by: string | null
          description: string | null
          id: string | null
          last_note_at: string | null
          note_count: number | null
          organization_count: number | null
          people_count: number | null
          status: string | null
          title: string | null
          updated_at: string | null
        }
        Relationships: [
          {
            foreignKeyName: "cases_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      organizations_overview: {
        Row: {
          confirmed_member_count: number | null
          created_at: string | null
          created_by: string | null
          id: string | null
          last_note_at: string | null
          member_count: number | null
          name: string | null
          note_count: number | null
          notes: string | null
          status: string | null
          territory: string | null
          type: string | null
          updated_at: string | null
        }
        Relationships: [
          {
            foreignKeyName: "organizations_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      people_overview: {
        Row: {
          alias: string | null
          created_at: string | null
          created_by: string | null
          description: string | null
          display_name: string | null
          id: string | null
          last_note_at: string | null
          name: string | null
          note_count: number | null
          organizations: Json | null
          photo_path: string | null
          plates: string[] | null
          status: string | null
          updated_at: string | null
        }
        Relationships: [
          {
            foreignKeyName: "people_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Functions: {
      blank_to_null: {
        Args: { v: string }
        Returns: string
      }
      distinct_tags: {
        Args: Record<PropertyKey, never>
        Returns: { tag: string; uses: number }[]
      }
      merge_people: {
        Args: { keep_id: string; drop_id: string }
        Returns: string
      }
      normalize_plate: {
        Args: { v: string }
        Returns: string
      }
      normalize_tags: {
        Args: { v: string[] }
        Returns: string[]
      }
      search_all: {
        Args: { term: string; per_type?: number }
        Returns: {
          kind: string
          id: string
          title: string
          subtitle: string | null
          status: string | null
          score: number
          /** The record this result belongs to, for results with no page of their own. */
          parent_kind: string | null
          parent_id: string | null
        }[]
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type PublicSchema = Database["public"]

export type Tables<T extends keyof PublicSchema["Tables"]> = PublicSchema["Tables"][T]["Row"]
export type TablesInsert<T extends keyof PublicSchema["Tables"]> = PublicSchema["Tables"][T]["Insert"]
export type TablesUpdate<T extends keyof PublicSchema["Tables"]> = PublicSchema["Tables"][T]["Update"]
export type Views<T extends keyof PublicSchema["Views"]> = PublicSchema["Views"][T]["Row"]
export type FunctionReturns<T extends keyof PublicSchema["Functions"]> = PublicSchema["Functions"][T]["Returns"]
