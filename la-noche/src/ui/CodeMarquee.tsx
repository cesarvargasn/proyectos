import { motion } from 'framer-motion'

/**
 * Elemento firma de La Noche: el código de sala.
 * Letras en bloques que entran con pop escalonado,
 * sobre una banda marquee que corre en loop.
 */
export function CodeMarquee({ code }: { code: string }) {
  const letters = code.toUpperCase().slice(0, 4).split('')
  const band = `★ LA NOCHE ★ CÓDIGO ${code.toUpperCase()} `.repeat(4)

  return (
    <div style={{ position: 'relative', padding: '28px 0', overflow: 'hidden' }}>
      {/* banda marquee */}
      <div
        style={{
          position: 'absolute',
          top: '50%',
          left: 0,
          right: 0,
          transform: 'translateY(-50%)',
          borderTop: 'var(--border-thin)',
          borderBottom: 'var(--border-thin)',
          background: 'var(--amber)',
          overflow: 'hidden',
          whiteSpace: 'nowrap',
        }}
      >
        <motion.div
          animate={{ x: ['0%', '-50%'] }}
          transition={{ duration: 14, ease: 'linear', repeat: Infinity }}
          style={{
            display: 'inline-block',
            fontFamily: 'var(--font-display)',
            fontSize: '0.85rem',
            color: '#000',
            padding: '6px 0',
          }}
        >
          {band + band}
        </motion.div>
      </div>

      {/* letras del código */}
      <div style={{ position: 'relative', display: 'flex', gap: '10px', justifyContent: 'center' }}>
        {letters.map((letter, i) => (
          <motion.div
            key={i}
            initial={{ scale: 0, rotate: -8 + i * 5 }}
            animate={{ scale: 1, rotate: 0 }}
            transition={{ type: 'spring', stiffness: 400, damping: 18, delay: 0.15 * i }}
            style={{
              fontFamily: 'var(--font-display)',
              fontSize: 'clamp(3rem, 16vw, 5.5rem)',
              lineHeight: 1,
              background: 'var(--bg)',
              border: 'var(--border)',
              boxShadow: 'var(--shadow)',
              padding: '10px 16px',
            }}
          >
            {letter}
          </motion.div>
        ))}
      </div>
    </div>
  )
}
