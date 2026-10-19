import {
  CreateStartUpPageContainer,
  MenuContainerProperty,
  MenuItemProperty,
  OsEventTypeList,
  TextContainerProperty,
  TextContainerUpgrade,
  waitForEvenAppBridge,
  type EvenAppBridge,
} from '@evenrealities/even_hub_sdk'
import { paginate } from './paginate'
import './style.css'

const RELAY_URL = 'http://127.0.0.1:8765/api/questions'
const BODY_WIDTH = 576
const BODY_HEIGHT = 240
const BODY_PADDING = 4
const INNER_WIDTH = BODY_WIDTH - BODY_PADDING * 2
const INNER_HEIGHT = BODY_HEIGHT - BODY_PADDING * 2
const POLL_INTERVAL_MS = 750
const MAX_LOCAL_QUESTIONS = 100

interface RelayQuestion {
  sequence: number
  question_number: string
  question: string
  answer: string
  certainty: string
  received_at: string
}

interface RelayEnvelope {
  session_id: string
  latest_sequence: number
  questions: RelayQuestion[]
}

interface SavedState {
  sessionID: string
  latestSequence: number
  questions: RelayQuestion[]
  currentQuestionIndex: number
  currentPageIndex: number
}

const connectionElement = requiredElement<HTMLElement>('#connection')
const questionCountElement = requiredElement<HTMLElement>('#question-count')
const pageCountElement = requiredElement<HTMLElement>('#page-count')
const mirrorElement = requiredElement<HTMLElement>('#mirror')

let bridge: EvenAppBridge
let sessionID = ''
let latestSequence = 0
let questions: RelayQuestion[] = []
let currentQuestionIndex = -1
let currentPageIndex = 0
let currentPages = ['请在手机打开 Pen Camera\n并点击 Start G2 Analysis']
let pollTimer: number | undefined
let rendering: Promise<unknown> = Promise.resolve()
let stopped = false

restoreState()

function requiredElement<T extends Element>(selector: string): T {
  const element = document.querySelector<T>(selector)
  if (!element) throw new Error(`Missing companion element: ${selector}`)
  return element
}

function menu(): MenuContainerProperty {
  return new MenuContainerProperty({
    menuItems: [
      new MenuItemProperty({ itemName: '上一页', itemID: 1 }),
      new MenuItemProperty({ itemName: '下一页', itemID: 2 }),
      new MenuItemProperty({ itemName: '上一题', itemID: 3 }),
      new MenuItemProperty({ itemName: '下一题', itemID: 4 }),
      new MenuItemProperty({ itemName: '刷新', itemID: 5 }),
    ],
  })
}

function questionDocument(question: RelayQuestion): string {
  const uncertainty = question.certainty === 'uncertain' ? '（识别可能不完整）' : ''
  return `第 ${question.question_number} 题${uncertainty}\n\n${question.question}\n\n答案：${question.answer}`
}

function updatePages(): void {
  const question = questions[currentQuestionIndex]
  currentPages = question
    ? paginate(questionDocument(question), { width: INNER_WIDTH, height: INNER_HEIGHT })
    : ['请在手机打开 Pen Camera\n并点击 Start G2 Analysis']
  currentPageIndex = Math.min(Math.max(0, currentPageIndex), currentPages.length - 1)
}

function footerLabel(): string {
  if (currentQuestionIndex < 0) return '等待题目 · 双击退出'
  return `题 ${currentQuestionIndex + 1}/${questions.length} · 页 ${currentPageIndex + 1}/${currentPages.length} · 点击/下滑继续`
}

async function render(): Promise<void> {
  updatePages()
  const body = currentPages[currentPageIndex] ?? '等待完整题目'
  const footer = footerLabel()
  rendering = rendering.then(async () => {
    await bridge.textContainerUpgrade(new TextContainerUpgrade({
      containerID: 1,
      containerName: 'questionBody',
      content: body,
      textColor: 4,
    }))
    await bridge.textContainerUpgrade(new TextContainerUpgrade({
      containerID: 2,
      containerName: 'questionPager',
      content: footer,
      textColor: 3,
    }))
  })
  await rendering
  mirrorElement.textContent = body
  questionCountElement.textContent = `${questions.length} 道题`
  pageCountElement.textContent = currentQuestionIndex < 0
    ? '—'
    : `第 ${currentQuestionIndex + 1} 题 · ${currentPageIndex + 1}/${currentPages.length} 页`
  persistState()
}

function nextPage(): void {
  if (currentPageIndex + 1 < currentPages.length) {
    currentPageIndex += 1
  } else if (currentQuestionIndex + 1 < questions.length) {
    currentQuestionIndex += 1
    currentPageIndex = 0
  }
  void render()
}

function previousPage(): void {
  if (currentPageIndex > 0) {
    currentPageIndex -= 1
  } else if (currentQuestionIndex > 0) {
    currentQuestionIndex -= 1
    updatePages()
    currentPageIndex = currentPages.length - 1
  }
  void render()
}

function changeQuestion(offset: number): void {
  if (questions.length === 0) return
  currentQuestionIndex = Math.min(
    questions.length - 1,
    Math.max(0, currentQuestionIndex + offset),
  )
  currentPageIndex = 0
  void render()
}

function eventTypeOf(envelope?: { eventType?: OsEventTypeList }): OsEventTypeList | null {
  if (!envelope) return null
  return envelope.eventType ?? OsEventTypeList.CLICK_EVENT
}

function isRelayEnvelope(value: unknown): value is RelayEnvelope {
  if (!value || typeof value !== 'object') return false
  const candidate = value as Partial<RelayEnvelope>
  return typeof candidate.session_id === 'string'
    && typeof candidate.latest_sequence === 'number'
    && Array.isArray(candidate.questions)
}

async function poll(): Promise<void> {
  if (stopped) return
  let retryImmediately = false
  try {
    const response = await fetch(`${RELAY_URL}?after=${latestSequence}`, {
      cache: 'no-store',
      signal: AbortSignal.timeout(2_500),
    })
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    const payload: unknown = await response.json()
    if (!isRelayEnvelope(payload)) throw new Error('Invalid relay response')

    if (sessionID && payload.session_id !== sessionID) {
      sessionID = payload.session_id
      latestSequence = 0
      questions = []
      currentQuestionIndex = -1
      currentPageIndex = 0
      retryImmediately = true
    } else {
      sessionID = payload.session_id
      const incoming = payload.questions
        .filter((question) => question && typeof question.sequence === 'number')
        .sort((left, right) => left.sequence - right.sequence)
      if (incoming.length > 0) {
        const known = new Set(questions.map((question) => question.sequence))
        questions.push(...incoming.filter((question) => !known.has(question.sequence)))
        questions = questions.slice(-MAX_LOCAL_QUESTIONS)
        currentQuestionIndex = questions.length - 1
        currentPageIndex = 0
        await render()
      }
      latestSequence = Math.max(latestSequence, payload.latest_sequence)
      connectionElement.textContent = '已连接 Pen Camera，完整题目会自动显示到眼镜。'
      persistState()
    }
  } catch (error) {
    connectionElement.textContent = '等待 Pen Camera：请保持手机端应用打开并开始分析。'
    console.debug('Pen Camera relay unavailable', error)
  } finally {
    if (!stopped) pollTimer = window.setTimeout(() => void poll(), retryImmediately ? 0 : POLL_INTERVAL_MS)
  }
}

function persistState(): void {
  const state: SavedState = {
    sessionID,
    latestSequence,
    questions,
    currentQuestionIndex,
    currentPageIndex,
  }
  localStorage.setItem('pen-camera-g2-state', JSON.stringify(state))
}

function restoreState(): void {
  try {
    const raw = localStorage.getItem('pen-camera-g2-state')
    if (!raw) return
    const saved = JSON.parse(raw) as Partial<SavedState>
    sessionID = typeof saved.sessionID === 'string' ? saved.sessionID : ''
    latestSequence = typeof saved.latestSequence === 'number' ? saved.latestSequence : 0
    questions = Array.isArray(saved.questions) ? saved.questions.slice(-MAX_LOCAL_QUESTIONS) : []
    currentQuestionIndex = typeof saved.currentQuestionIndex === 'number'
      ? Math.min(saved.currentQuestionIndex, questions.length - 1)
      : questions.length - 1
    currentPageIndex = typeof saved.currentPageIndex === 'number' ? saved.currentPageIndex : 0
  } catch {
    localStorage.removeItem('pen-camera-g2-state')
  }
}

async function start(): Promise<void> {
  bridge = await waitForEvenAppBridge()
  updatePages()
  const created = await bridge.createStartUpPageContainer(new CreateStartUpPageContainer({
    containerTotalNum: 2,
    textObject: [
      new TextContainerProperty({
        xPosition: 0,
        yPosition: 0,
        width: BODY_WIDTH,
        height: BODY_HEIGHT,
        borderWidth: 0,
        paddingLength: BODY_PADDING,
        containerID: 1,
        containerName: 'questionBody',
        content: currentPages[currentPageIndex],
        textColor: 4,
        isEventCapture: 1,
      }),
      new TextContainerProperty({
        xPosition: 0,
        yPosition: 250,
        width: 576,
        height: 30,
        borderWidth: 0,
        paddingLength: 4,
        containerID: 2,
        containerName: 'questionPager',
        content: footerLabel(),
        textColor: 3,
        isEventCapture: 0,
      }),
    ],
    menuObject: menu(),
  }))
  if (created !== 0) throw new Error(`Even G2 page creation failed: ${String(created)}`)

  const unsubscribe = bridge.onEvenHubEvent((event) => {
    const sysType = eventTypeOf(event.sysEvent)
    const textType = eventTypeOf(event.textEvent)
    if (sysType === OsEventTypeList.DOUBLE_CLICK_EVENT || textType === OsEventTypeList.DOUBLE_CLICK_EVENT) {
      void bridge.shutDownPageContainer(1)
      return
    }
    if (textType === OsEventTypeList.SCROLL_TOP_EVENT) {
      previousPage()
      return
    }
    if (textType === OsEventTypeList.SCROLL_BOTTOM_EVENT) {
      nextPage()
      return
    }
    if (sysType === OsEventTypeList.CLICK_EVENT || textType === OsEventTypeList.CLICK_EVENT) {
      nextPage()
      return
    }

    switch (event.menuItemClickEvent?.itemID) {
    case 1: previousPage(); break
    case 2: nextPage(); break
    case 3: changeQuestion(-1); break
    case 4: changeQuestion(1); break
    case 5: void poll(); break
    default: break
    }

    if (sysType === OsEventTypeList.SYSTEM_EXIT_EVENT || sysType === OsEventTypeList.ABNORMAL_EXIT_EVENT) {
      stopped = true
      if (pollTimer !== undefined) window.clearTimeout(pollTimer)
      unsubscribe()
    }
  })

  window.addEventListener('beforeunload', () => {
    stopped = true
    if (pollTimer !== undefined) window.clearTimeout(pollTimer)
    unsubscribe()
  }, { once: true })

  await render()
  void poll()
}

void start().catch((error: unknown) => {
  console.error(error)
  connectionElement.textContent = error instanceof Error ? error.message : 'Even G2 插件启动失败'
})
