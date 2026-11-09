import { tipsFor } from '../data/tips'
import type { TipModule } from '../types'

/** Lista de trucos del módulo. Contenido vive en src/data/tips.ts. */
export function TipList({ module, title = 'Trucos' }: { module: TipModule; title?: string }) {
  const tips = tipsFor(module)
  if (tips.length === 0) return null

  return (
    <section className="panel p-4">
      <h3 className="label mb-3">{title}</h3>
      <ul className="grid gap-3 md:grid-cols-2">
        {tips.map((t) => (
          <li key={t.id} className="border-l-2 border-orange/70 pl-3">
            <p className="text-sm font-medium text-orange">{t.title}</p>
            <p className="text-sm text-ink/85 mt-0.5 leading-snug">{t.body}</p>
            <div className="flex gap-1 mt-1.5 flex-wrap">
              {t.tags.map((tag) => (
                <span key={tag} className="chip">
                  {tag}
                </span>
              ))}
            </div>
          </li>
        ))}
      </ul>
    </section>
  )
}
