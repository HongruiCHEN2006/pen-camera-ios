import {
  CreateStartUpPageContainer,
  EventSourceType,
  ImageContainerProperty,
  ImageRawDataUpdate,
  MenuContainerProperty,
  MenuItemProperty,
  OsEventTypeList,
  RebuildPageContainer,
  TextContainerProperty,
  TextContainerUpgrade,
  waitForEvenAppBridge,
  type EvenAppBridge,
  type Sys_ItemEvent,
} from '@evenrealities/even_hub_sdk'
import { paginate } from './paginate'
import './style.css'

const RELAY_URL = 'http://127.0.0.1:8765'
const BODY_WIDTH = 576
const BODY_HEIGHT = 240
const BODY_PADDING = 4
const POLL_INTERVAL_MS = 750
const MAX_LOCAL_QUESTIONS = 100
const ARM_WINDOW_MS = 2_500

type CaptureMode = 'manual_capture' | 'black_screen_detection'
type ViewKind = 'answers' | 'mode_picker' | 'preview'

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
  questions: RelayQuestion[]
}

interface RelayStatus {
  mode: CaptureMode
  preview_sequence: number
}

interface SavedState {
  sessionID: string
  latestSequence: number
  questions: RelayQuestion[]
  viewportIndex: number
  captureMode: CaptureMode
}

const connectionElement = requiredElement<HTMLElement>('#connection')
const questionCountElement = requiredElement<HTMLElement>('#question-count')
const pageCountElement = requiredElement<HTMLElement>('#page-count')
const mirrorElement = requiredElement<HTMLElement>('#mirror')

let bridge: EvenAppBridge
let sessionID = ''
let latestSequence = 0
let questions: RelayQuestion[] = []
let viewportIndex = 0
let captureMode: CaptureMode = 'black_screen_detection'
let view: ViewKind = 'answers'
let modeSelection: CaptureMode = captureMode
let screens = ['等待手机端题目']
let activeLayout: ViewKind = 'answers'
let previewSequence = 0
let leftClickArmedUntil = 0
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
      new MenuItemProperty({ itemName: '切换模式', itemID: 1 }),
      new MenuItemProperty({ itemName: '手动拍照', itemID: 2 }),
      new MenuItemProperty({ itemName: '黑屏检测', itemID: 3 }),
      new MenuItemProperty({ itemName: '清空答案', itemID: 4 }),
      new MenuItemProperty({ itemName: '刷新', itemID: 5 }),
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
  for (const group of groups) group.sort((a, b) => a.batch_index - b.batch_index)
  return groups
}

function answerDocument(): string {
  if (questions.length === 0) {
    return '等待答案\n\n左镜腿：单击后长按进入模式选择\n右镜腿：双击退出'
  }
  return batchGroups().map((batch, batchIndex) => {
    const summary = batch.map((question) =>
      `${question.question_number}. ${brief(question.question)}\n答案：${question.answer}`,
    ).join('\n\n')
    const details = batch.map((question) => {
      const uncertain = question.certainty === 'uncertain' ? '（识别可能不完整）' : ''
      return `第 ${question.question_number} 题${uncertain}\n${question.question}\n答案：${question.answer}`
    }).join('\n\n────────\n\n')
    return `第 ${batchIndex + 1} 批 · 简短答案\n\n${summary}\n\n第 ${batchIndex + 1} 批 · 完整题目与答案\n\n${details}`
  }).join('\n\n════════\n\n')
}

function updateScreens(): void {
  screens = paginate(answerDocument(), {
    width: BODY_WIDTH - BODY_PADDING * 2,
    height: BODY_HEIGHT - BODY_PADDING * 2,
  })
  viewportIndex = Math.min(Math.max(0, viewportIndex), screens.length - 1)
}

function answerFooter(): string {
  return questions.length === 0
    ? '等待题目 · 单击后长按：模式'
    : `共 ${questions.length} 题 · 滑动/单击滚动 · 单击后长按清空`
}

function answerContainers() {
  updateScreens()
  return {
    containerTotalNum: 2,
    textObject: [
      new TextContainerProperty({
        xPosition: 0, yPosition: 0, width: 576, height: 240,
        borderWidth: 0, paddingLength: BODY_PADDING,
        containerID: 1, containerName: 'questionBody',
        content: screens[viewportIndex], textColor: 4, isEventCapture: 1,
      }),
      new TextContainerProperty({
        xPosition: 0, yPosition: 250, width: 576, height: 30,
        borderWidth: 0, paddingLength: 4,
        containerID: 2, containerName: 'questionPager',
        content: answerFooter(), textColor: 3, isEventCapture: 0,
      }),
    ],
    menuObject: menu(),
  }
}

function pickerText(): string {
  const first = modeSelection === 'manual_capture' ? '▶' : ' '
  const second = modeSelection === 'black_screen_detection' ? '▶' : ' '
  return `切换模式（只能选择一个）\n\n${first} 1. 控制拍照\n低帧率取景；左单击在1秒内拍3张；左双击结束并统一上传。\n\n${second} 2. 黑屏检测\n保持原流程，检测黑屏后统一上传。`
}

function pickerContainers() {
  return {
    containerTotalNum: 2,
    textObject: [
      new TextContainerProperty({
        xPosition: 0, yPosition: 0, width: 576, height: 240,
        borderWidth: 0, paddingLength: 4,
        containerID: 1, containerName: 'questionBody',
        content: pickerText(), textColor: 4, isEventCapture: 1,
      }),
      new TextContainerProperty({
        xPosition: 0, yPosition: 250, width: 576, height: 30,
        borderWidth: 0, paddingLength: 4,
        containerID: 2, containerName: 'questionPager',
        content: '上下滑动选择 · 左单击确认', textColor: 3, isEventCapture: 0,
      }),
    ],
    menuObject: menu(),
  }
}

function previewContainers() {
  return {
    containerTotalNum: 3,
    textObject: [
      new TextContainerProperty({
        xPosition: 0, yPosition: 0, width: 576, height: 288,
        borderWidth: 0, paddingLength: 4,
        containerID: 1, containerName: 'questionBody',
        content: '手动拍照 · 低帧率取景', textColor: 4, isEventCapture: 1,
      }),
      new TextContainerProperty({
        xPosition: 0, yPosition: 226, width: 576, height: 54,
        borderWidth: 0, paddingLength: 4,
        containerID: 2, containerName: 'questionPager',
        content: '左单击：1秒拍3张 · 左双击：结束并上传', textColor: 3, isEventCapture: 0,
      }),
    ],
    imageObject: [
      new ImageContainerProperty({
        xPosition: 144, yPosition: 60, width: 288, height: 144,
        containerID: 3, containerName: 'cameraPreview',
      }),
    ],
    menuObject: menu(),
  }
}

async function rebuild(target: ViewKind): Promise<void> {
  const definition = target === 'preview'
    ? previewContainers()
    : target === 'mode_picker' ? pickerContainers() : answerContainers()
  const ok = await bridge.rebuildPageContainer(new RebuildPageContainer(definition))
  if (!ok) throw new Error(`G2 layout rebuild failed: ${target}`)
  activeLayout = target
}

async function render(): Promise<void> {
  rendering = rendering.then(async () => {
    if (activeLayout !== view) await rebuild(view)
    if (view === 'answers') {
      updateScreens()
      await bridge.textContainerUpgrade(new TextContainerUpgrade({
        containerID: 1, containerName: 'questionBody',
        content: screens[viewportIndex] ?? '等待题目', textColor: 4,
      }))
      await bridge.textContainerUpgrade(new TextContainerUpgrade({
        containerID: 2, containerName: 'questionPager', content: answerFooter(), textColor: 3,
      }))
    } else if (view === 'mode_picker') {
      await bridge.textContainerUpgrade(new TextContainerUpgrade({
        containerID: 1, containerName: 'questionBody', content: pickerText(), textColor: 4,
      }))
    }
  })
  await rendering
  const mirror = view === 'answers' ? screens[viewportIndex] : view === 'mode_picker' ? pickerText() : 'Camera preview'
  mirrorElement.textContent = mirror
  questionCountElement.textContent = `${questions.length} 道题`
  pageCountElement.textContent = view === 'answers' ? '连续滚动' : view
  persistState()
}

function scrollScreens(offset: number): void {
  if (view === 'mode_picker') {
    modeSelection = offset < 0 ? 'manual_capture' : 'black_screen_detection'
  } else if (view === 'answers') {
    viewportIndex = Math.min(screens.length - 1, Math.max(0, viewportIndex + offset))
  }
  void render()
}

async function sendControl(action: string, mode?: CaptureMode): Promise<void> {
  const params = new URLSearchParams({ action })
  if (mode) params.set('mode', mode)
  const response = await fetch(`${RELAY_URL}/api/control?${params.toString()}`, {
    cache: 'no-store', signal: AbortSignal.timeout(2_500),
  })
  if (!response.ok && response.status !== 204) throw new Error(`Control HTTP ${response.status}`)
}

async function chooseMode(mode: CaptureMode): Promise<void> {
  await sendControl('set_mode', mode)
  captureMode = mode
  modeSelection = mode
  view = mode === 'manual_capture' ? 'preview' : 'answers'
  await render()
}

async function clearAnswers(): Promise<void> {
  await sendControl('clear_answers')
  questions = []
  latestSequence = 0
  viewportIndex = 0
  view = 'answers'
  updateScreens()
  await render()
}

function eventTypeOf(envelope?: { eventType?: OsEventTypeList }): OsEventTypeList | null {
  return envelope?.eventType ?? null
}

function eventSourceOf(envelope?: Sys_ItemEvent): EventSourceType | null {
  return envelope?.eventSource ?? null
}

function isLeft(source: EventSourceType | null): boolean {
  return source === EventSourceType.TOUCH_EVENT_FROM_GLASSES_L
}

function isRight(source: EventSourceType | null): boolean {
  return source === EventSourceType.TOUCH_EVENT_FROM_GLASSES_R
}

async function handleGesture(type: OsEventTypeList, source: EventSourceType | null): Promise<void> {
  if (type === OsEventTypeList.CLICK_EVENT) {
    if (isLeft(source)) {
      leftClickArmedUntil = Date.now() + ARM_WINDOW_MS
      if (view === 'mode_picker') await chooseMode(modeSelection)
      else if (view === 'preview') await sendControl('capture_burst')
      else scrollScreens(1)
    } else {
      scrollScreens(1)
    }
    return
  }
  if (type === OsEventTypeList.LONG_PRESS_EVENT && isLeft(source)) {
    if (Date.now() > leftClickArmedUntil) return
    leftClickArmedUntil = 0
    if (view === 'answers' && questions.length > 0) await clearAnswers()
    else {
      modeSelection = captureMode
      view = 'mode_picker'
      await render()
    }
    return
  }
  if (type === OsEventTypeList.DOUBLE_CLICK_EVENT) {
    if (isLeft(source) && view === 'preview') {
      await sendControl('finish_capture')
      view = 'answers'
      await render()
    } else if (isRight(source) || source === null) {
      await bridge.shutDownPageContainer(1)
    }
    return
  }
  if (type === OsEventTypeList.SCROLL_TOP_EVENT) scrollScreens(-1)
  if (type === OsEventTypeList.SCROLL_BOTTOM_EVENT) scrollScreens(1)
}

function isRelayEnvelope(value: unknown): value is RelayEnvelope {
  if (!value || typeof value !== 'object') return false
  const candidate = value as Partial<RelayEnvelope>
  return typeof candidate.session_id === 'string'
    && typeof candidate.latest_sequence === 'number'
    && Array.isArray(candidate.questions)
}

async function pollPreview(): Promise<void> {
  if (view !== 'preview' || captureMode !== 'manual_capture') return
  const response = await fetch(`${RELAY_URL}/api/preview?after=${previewSequence}`, {
    cache: 'no-store', signal: AbortSignal.timeout(2_500),
  })
  if (response.status === 204) return
  if (!response.ok) throw new Error(`Preview HTTP ${response.status}`)
  const next = Number(response.headers.get('X-Preview-Sequence'))
  const image = new Uint8Array(await response.arrayBuffer())
  if (image.length === 0) return
  rendering = rendering.then(async () => {
    if (view !== 'preview') return
    await bridge.updateImageRawData(new ImageRawDataUpdate({
      containerID: 3, containerName: 'cameraPreview', imageData: image,
    }))
  })
  await rendering
  if (Number.isFinite(next)) previewSequence = next
}

async function poll(): Promise<void> {
  if (stopped) return
  let retryImmediately = false
  try {
    const [questionResponse, statusResponse] = await Promise.all([
      fetch(`${RELAY_URL}/api/questions?after=${latestSequence}`, {
        cache: 'no-store', signal: AbortSignal.timeout(2_500),
      }),
      fetch(`${RELAY_URL}/api/status`, {
        cache: 'no-store', signal: AbortSignal.timeout(2_500),
      }),
    ])
    if (!questionResponse.ok || !statusResponse.ok) throw new Error('Relay unavailable')
    const payload: unknown = await questionResponse.json()
    const status = await statusResponse.json() as RelayStatus
    if (!isRelayEnvelope(payload)) throw new Error('Invalid relay response')

    captureMode = status.mode
    if (sessionID && payload.session_id !== sessionID) {
      sessionID = payload.session_id
      latestSequence = 0
      questions = []
      viewportIndex = 0
      retryImmediately = true
      if (view === 'answers') await render()
    } else {
      sessionID = payload.session_id
      const incoming = payload.questions
        .filter((question) => question && typeof question.sequence === 'number')
        .sort((left, right) => left.sequence - right.sequence)
      if (incoming.length > 0) {
        const priorScreenCount = screens.length
        const known = new Set(questions.map((question) => question.sequence))
        questions.push(...incoming.filter((question) => !known.has(question.sequence)))
        questions = questions.slice(-MAX_LOCAL_QUESTIONS)
        updateScreens()
        viewportIndex = Math.min(priorScreenCount, screens.length - 1)
        view = 'answers'
        await render()
      }
      latestSequence = Math.max(latestSequence, payload.latest_sequence)
      await pollPreview()
      connectionElement.textContent = '已连接 Pen Camera；眼镜控制与答案同步已启用。'
      persistState()
    }
  } catch (error) {
    connectionElement.textContent = '等待 Pen Camera：请保持手机端应用打开并开始 G2 分析。'
    console.debug('Pen Camera relay unavailable', error)
  } finally {
    if (!stopped) pollTimer = window.setTimeout(() => void poll(), retryImmediately ? 0 : POLL_INTERVAL_MS)
  }
}

function persistState(): void {
  const state: SavedState = { sessionID, latestSequence, questions, viewportIndex, captureMode }
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
    viewportIndex = typeof saved.viewportIndex === 'number' ? saved.viewportIndex : 0
    captureMode = saved.captureMode === 'manual_capture' ? 'manual_capture' : 'black_screen_detection'
    modeSelection = captureMode
  } catch {
    localStorage.removeItem('pen-camera-g2-state')
  }
}

async function start(): Promise<void> {
  bridge = await waitForEvenAppBridge()
  const created = await bridge.createStartUpPageContainer(new CreateStartUpPageContainer(answerContainers()))
  if (created !== 0) throw new Error(`Even G2 page creation failed: ${String(created)}`)

  const unsubscribe = bridge.onEvenHubEvent((event) => {
    // Current G2 firmware reports source-aware temple gestures as sysEvent.
    // Fall back to textEvent for the simulator and older host builds.
    const envelope = event.sysEvent ?? event.textEvent
    const type = eventTypeOf(envelope)
    if (type !== null) void handleGesture(type, eventSourceOf(event.sysEvent))

    switch (event.menuItemClickEvent?.itemID) {
    case 1:
      modeSelection = captureMode
      view = 'mode_picker'
      void render()
      break
    case 2: void chooseMode('manual_capture'); break
    case 3: void chooseMode('black_screen_detection'); break
    case 4: void clearAnswers(); break
    case 5: void poll(); break
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
