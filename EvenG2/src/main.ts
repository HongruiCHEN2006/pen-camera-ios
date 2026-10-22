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

const APP_VERSION = '0.4.0'
const RELAY_URL = 'http://127.0.0.1:8765/api/questions'
const BODY_WIDTH = 576
const BODY_HEIGHT = 240
const BODY_PADDING = 4
const POLL_INTERVAL_MS = 750
const MAX_LOCAL_QUESTIONS = 100

interface RelayQuestion {
  sequence: number
  batch_id: string
  batch_index: number
  batch_total: number
  question_number: string
  question: string
  answer: string
  certainty: string
  received_at: string
}

interface RelayEnvelope {
  session_id: string
  latest_sequence: number
  camera: CameraStatus
  questions: RelayQuestion[]
}

interface CameraStatus {
  connected: boolean
  state: string
  battery_level?: number | null
  updated_at: string
}

interface SavedState {
  sessionID: string
  latestSequence: number
  questions: RelayQuestion[]
  scrollPosition: number
}

const connectionElement = requiredElement<HTMLElement>('#connection')
const questionCountElement = requiredElement<HTMLElement>('#question-count')
const pageCountElement = requiredElement<HTMLElement>('#page-count')
const mirrorElement = requiredElement<HTMLElement>('#mirror')

let bridge: EvenAppBridge
let sessionID = ''
let latestSequence = 0
let questions: RelayQuestion[] = []
let cameraStatus: CameraStatus = {
  connected: false,
  state: 'disconnected',
  battery_level: null,
  updated_at: '',
}
let scrollPosition = 0
let viewports = ['等待答案']
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
      new MenuItemProperty({ itemName: '向上滚动', itemID: 1 }),
      new MenuItemProperty({ itemName: '向下滚动', itemID: 2 }),
      new MenuItemProperty({ itemName: '清空答案', itemID: 3 }),
      new MenuItemProperty({ itemName: '刷新', itemID: 4 }),
    ],
  })
}

function brief(text: string): string {
  const clean = text.replace(/\s+/gu, ' ').trim()
  if (!clean) return '未识别题干'
  const words = clean.split(' ')
  if (words.length > 4) return `${words.slice(0, 7).join(' ')}…`
  return clean.length > 28 ? `${Array.from(clean).slice(0, 28).join('')}…` : clean
}

function batchGroups(): RelayQuestion[][] {
  const groups: RelayQuestion[][] = []
  const byID = new Map<string, RelayQuestion[]>()
  for (const question of questions) {
    const id = question.batch_id || `legacy-${question.sequence}`
    let group = byID.get(id)
    if (!group) {
      group = []
      byID.set(id, group)
      groups.push(group)
    }
    group.push(question)
  }
  for (const group of groups) group.sort((left, right) => left.batch_index - right.batch_index)
  return groups
}

function answerDocument(): string {
  const cameraLine = cameraStatus.connected
    ? `相机：已连接${typeof cameraStatus.battery_level === 'number' ? ` · 电量 ${cameraStatus.battery_level}%` : ''}`
    : `相机：${cameraStatus.state === 'connecting' ? '连接中' : cameraStatus.state === 'reconnecting' ? '正在重连' : '未连接'}`

  if (questions.length === 0) {
    return `Pen Camera G2 v${APP_VERSION}\n${cameraLine}\n\n等待黑屏检测上传结果\n\n滑动滚动 · 单击下移 · 双击退出`
  }

  const answers = batchGroups().map((batch, batchIndex) => {
    const quickAnswers = batch.map((question) =>
      `${question.question_number}. ${brief(question.question)}\n大概答案：${question.answer}`,
    ).join('\n\n')

    const fullAnswers = batch.map((question) => {
      const uncertain = question.certainty === 'uncertain' ? '（识别可能不完整）' : ''
      return `第 ${question.question_number} 题${uncertain}\n${question.question}\n具体答案：${question.answer}`
    }).join('\n\n────────\n\n')

    return `第 ${batchIndex + 1} 批 · 答案速览\n\n${quickAnswers}\n\n第 ${batchIndex + 1} 批 · 完整题目与具体答案\n\n${fullAnswers}`
  }).join('\n\n════════\n\n')
  return `Pen Camera G2 v${APP_VERSION}\n${cameraLine}\n\n${answers}`
}

function updateViewports(): void {
  viewports = paginate(answerDocument(), {
    width: BODY_WIDTH - BODY_PADDING * 2,
    height: BODY_HEIGHT - BODY_PADDING * 2,
  })
  scrollPosition = Math.min(Math.max(0, scrollPosition), viewports.length - 1)
}

function footer(): string {
  return questions.length === 0
    ? `v${APP_VERSION} · 等待答案 · 双击退出`
    : `共 ${questions.length} 题 · 滑动滚动 · 单击下移`
}

async function render(): Promise<void> {
  updateViewports()
  const body = viewports[scrollPosition] ?? '等待答案'
  rendering = rendering.then(async () => {
    await bridge.textContainerUpgrade(new TextContainerUpgrade({
      containerID: 1,
      containerName: 'answerScroll',
      content: body,
      textColor: 4,
    }))
    await bridge.textContainerUpgrade(new TextContainerUpgrade({
      containerID: 2,
      containerName: 'answerFooter',
      content: footer(),
      textColor: 3,
    }))
  })
  await rendering
  mirrorElement.textContent = body
  questionCountElement.textContent = `${questions.length} 道题`
  pageCountElement.textContent = '连续滚动'
  persistState()
}

function scroll(offset: number): void {
  updateViewports()
  scrollPosition = Math.min(viewports.length - 1, Math.max(0, scrollPosition + offset))
  void render()
}

function clearAnswers(): void {
  questions = []
  scrollPosition = 0
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
    && !!candidate.camera
    && typeof candidate.camera.connected === 'boolean'
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
    const cameraChanged = JSON.stringify(cameraStatus) !== JSON.stringify(payload.camera)
    cameraStatus = payload.camera

    if (sessionID && payload.session_id !== sessionID) {
      sessionID = payload.session_id
      latestSequence = 0
      questions = []
      scrollPosition = 0
      retryImmediately = true
      await render()
    } else {
      sessionID = payload.session_id
      const incoming = payload.questions
        .filter((question) => question && typeof question.sequence === 'number')
        .sort((left, right) => left.sequence - right.sequence)
      if (incoming.length > 0) {
        const hadQuestions = questions.length > 0
        const previousViewportCount = viewports.length
        const known = new Set(questions.map((question) => question.sequence))
        questions.push(...incoming.filter((question) => !known.has(question.sequence)))
        questions = questions.slice(-MAX_LOCAL_QUESTIONS)
        updateViewports()
        scrollPosition = hadQuestions ? Math.min(previousViewportCount, viewports.length - 1) : 0
        await render()
      } else if (cameraChanged) {
        await render()
      }
      latestSequence = Math.max(latestSequence, payload.latest_sequence)
      connectionElement.textContent = '已连接 Pen Camera；黑屏检测结果会自动显示。'
      persistState()
    }
  } catch (error) {
    connectionElement.textContent = '等待 Pen Camera：请在手机端启动黑屏检测分析。'
    console.debug('Pen Camera relay unavailable', error)
  } finally {
    if (!stopped) {
      pollTimer = window.setTimeout(() => void poll(), retryImmediately ? 0 : POLL_INTERVAL_MS)
    }
  }
}

function persistState(): void {
  const state: SavedState = { sessionID, latestSequence, questions, scrollPosition }
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
    scrollPosition = typeof saved.scrollPosition === 'number' ? saved.scrollPosition : 0
  } catch {
    localStorage.removeItem('pen-camera-g2-state')
  }
}

async function start(): Promise<void> {
  bridge = await waitForEvenAppBridge()
  updateViewports()
  const created = await bridge.createStartUpPageContainer(new CreateStartUpPageContainer({
    containerTotalNum: 2,
    textObject: [
      new TextContainerProperty({
        xPosition: 0, yPosition: 0, width: BODY_WIDTH, height: BODY_HEIGHT,
        borderWidth: 0, paddingLength: BODY_PADDING,
        containerID: 1, containerName: 'answerScroll',
        content: viewports[scrollPosition], textColor: 4, isEventCapture: 1,
      }),
      new TextContainerProperty({
        xPosition: 0, yPosition: 250, width: 576, height: 30,
        borderWidth: 0, paddingLength: 4,
        containerID: 2, containerName: 'answerFooter',
        content: footer(), textColor: 3, isEventCapture: 0,
      }),
    ],
    menuObject: menu(),
  }))
  if (created !== 0) throw new Error(`Even G2 page creation failed: ${String(created)}`)

  const unsubscribe = bridge.onEvenHubEvent((event) => {
    const envelope = event.sysEvent ?? event.textEvent ?? event.listEvent
    const type = eventTypeOf(envelope)
    if (type === OsEventTypeList.CLICK_EVENT || type === OsEventTypeList.SCROLL_BOTTOM_EVENT) {
      scroll(1)
    } else if (type === OsEventTypeList.SCROLL_TOP_EVENT) {
      scroll(-1)
    } else if (type === OsEventTypeList.DOUBLE_CLICK_EVENT) {
      void bridge.shutDownPageContainer(1)
    }

    switch (event.menuItemClickEvent?.itemID) {
    case 1: scroll(-1); break
    case 2: scroll(1); break
    case 3: clearAnswers(); break
    case 4: void poll(); break
    default: break
    }

    const sysType = eventTypeOf(event.sysEvent)
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
