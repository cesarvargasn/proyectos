import { motion } from 'framer-motion'

interface Props {
  text: string
  value: number | undefined
  onChange: (value: number) => void
}

const LABELS = [
  'Muy en desacuerdo',
  'En desacuerdo',
  'Neutral',
  'De acuerdo',
  'Muy de acuerdo',
]

export default function QuestionCard({ text, value, onChange }: Props) {
  return (
    <div className="question-card">
      <p className="question-text">{text}</p>

      <div className="likert-scale">
        {[1, 2, 3, 4, 5].map(n => (
          <motion.button
            key={n}
            type="button"
            className={`likert-btn ${value === n ? 'selected' : ''}`}
            onClick={() => onChange(n)}
            aria-label={LABELS[n - 1]}
            title={LABELS[n - 1]}
            whileTap={{ scale: 0.86 }}
            transition={{ type: 'spring', stiffness: 500, damping: 18 }}
          >
            {n}
          </motion.button>
        ))}
      </div>

      <div className="likert-labels">
        <span>{LABELS[0]}</span>
        <span>{LABELS[4]}</span>
      </div>
    </div>
  )
}
