import { measureTextWrap } from '@evenrealities/pretext'

const LINE_HEIGHT = 27

export interface PaginateBox {
  width: number
  height: number
}

export function paginate(source: string, box: PaginateBox): string[] {
  const maxLines = Math.max(1, Math.floor(box.height / LINE_HEIGHT))
  const paragraphs = source.split(/\n{2,}/).map((paragraph) => paragraph.trim()).filter(Boolean)
  const pages: string[] = []
  let buffer: string[] = []
  let bufferLines = 0

  const flush = (): void => {
    if (buffer.length === 0) return
    pages.push(buffer.join('\n\n'))
    buffer = []
    bufferLines = 0
  }

  for (const paragraph of paragraphs) {
    const paragraphLines = measureTextWrap(paragraph, box.width).lineCount
    if (paragraphLines > maxLines) {
      flush()
      pages.push(...splitParagraph(paragraph, box.width, maxLines))
      continue
    }

    const cost = paragraphLines + (buffer.length > 0 ? 1 : 0)
    if (bufferLines + cost > maxLines) flush()
    buffer.push(paragraph)
    bufferLines += paragraphLines + (buffer.length > 1 ? 1 : 0)
  }
  flush()
  return pages.length > 0 ? pages : ['等待完整题目']
}

function splitParagraph(text: string, width: number, maxLines: number): string[] {
  const tokens = text.match(/\s+|[^\s]+/gu) ?? Array.from(text)
  const chunks: string[] = []
  let current = ''

  const pushCurrent = (): void => {
    const clean = current.trim()
    if (clean) chunks.push(clean)
    current = ''
  }

  for (const token of tokens) {
    const candidate = current + token
    if (measureTextWrap(candidate, width).lineCount <= maxLines) {
      current = candidate
      continue
    }

    pushCurrent()
    if (measureTextWrap(token.trim(), width).lineCount <= maxLines) {
      current = token.trimStart()
      continue
    }

    for (const character of Array.from(token)) {
      const characterCandidate = current + character
      if (measureTextWrap(characterCandidate, width).lineCount > maxLines && current) {
        pushCurrent()
      }
      current += character
    }
  }
  pushCurrent()
  return chunks
}
