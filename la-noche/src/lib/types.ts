export interface Avatar {
  symbol: string
  color: string
}

export interface Party {
  id: string
  code: string
  status: 'lobby' | 'in_game' | 'ended'
  settings: { mode: 'social' | 'drinking'; intensity: number }
}

export interface Player {
  id: string
  party_id: string
  name: string
  avatar: Avatar
  is_host: boolean
  is_bot: boolean
  status: 'active' | 'left' | 'kicked'
  last_seen: string
}
