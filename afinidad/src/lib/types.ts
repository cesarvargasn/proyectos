export interface Event {
  id: string
  name: string
  code: string
  created_at: string
}

export interface Participant {
  id: string
  token: string
  event_id: string
  first_name: string
  email: string
  phone: string | null
  birthday: string | null
  completed_at: string | null
  created_at: string
}

export interface Question {
  id: string
  text: string
  text_en: string | null
  category: string
  weight: number
  deleted_at: string | null
  created_at: string
}

export type FeedbackType = 'rating' | 'boolean' | 'text'

export interface FeedbackQuestion {
  id: string
  text: string
  type: FeedbackType
  order_index: number
  active: boolean
  created_at: string
}

export interface EventQuestion {
  id: string
  event_id: string
  question_id: string
  display_order: number
  active: boolean
  questions: Question
}

export interface Answer {
  id: string
  participant_id: string
  question_id: string
  value: number
  created_at: string
}

export interface Match {
  id: string
  event_id: string
  participant_a: string
  participant_b: string
  score: number
  participant_a_data?: Pick<Participant, 'first_name'>
  participant_b_data?: Pick<Participant, 'first_name'>
}

export type EventPhase = 'waiting' | 'matching' | 'funnel' | 'countdown' | 'reveal'

export interface EventState {
  id: number
  event_id: string
  phase: EventPhase
  reveal_at: string | null
  admin_participates: boolean
  admin_participant_id: string | null
  admin_partner_id: string | null
  funnel_round?: number
}

export interface LocalSession {
  participantId: string
  token: string
  firstName: string
  eventId: string
  eventCode: string
}
