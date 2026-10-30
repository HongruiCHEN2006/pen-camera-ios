import {
  CreateStartUpPageContainer,
  EventSourceType,
  MenuContainerProperty,
  MenuItemProperty,
  OsEventTypeList,
  TextContainerProperty,
  TextContainerUpgrade,
  waitForEvenAppBridge,
  type EvenAppBridge,
  type Sys_ItemEvent,
} from '@evenrealities/even_hub_sdk'
import { paginate } from './paginate'
import './style.css'

const APP_VERSION = '0.8.0'
const RELAY_BASE = 'http://127.0.0.1:8765'
const RELAY_URL = `${RELAY_BASE}/api/questions`
const BODY_WIDTH = 576
const BODY_HEIGHT = 288
const BODY_PADDING = 4
const HEADER_HEIGHT = 27
const POLL_INTERVAL_MS = 750
const OCR_PREVIEW_INTERVAL_MS = 2_000
const MAX_LOCAL_QUESTIONS = 100
const ARM_WINDOW_MS = 2_500

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
  analysis: AnalysisStatus
  settings: RelaySettings
  ocr_preview?: OCRFrame | null
  questions: RelayQuestion[]
}

interface RelaySettings {
  profile: string
  profile_name: string
  upload_mode: 'images' | 'apple_vision'
  upload_mode_name: string
}

interface OCRBlock {
  text: string
  confidence: number
  x: number
  y: number
  width: number
  height: number
}

interface OCRFrame {
  frame_index: number
  blocks: OCRBlock[]
}

interface CameraStatus {
  connected: boolean
  state: string
  battery_level?: number | null
  updated_at: string
}

interface AnalysisStatus {
  is_black?: boolean | null
  upload_state: 'not_started' | 'started' | 'uploading' | 'success' | 'failed'
  image_count: number
}

interface SavedState {
  sessionID: string
  latestSequence: number
  questions: RelayQuestion[]
  scrollPosition: number
}

type ViewKind = 'main' | 'profile_picker' | 'upload_picker'

const PROFILE_OPTIONS = [
  { value: 'general', label: 'General' },
  { value: 'cs0447', label: 'CS 0447' },
  { value: 'introPsychology', label: 'Intro to Psychology' },
  { value: 'introMarketing', label: 'Intro to Marketing' },
] as const

const UPLOAD_OPTIONS = [
  { value: 'images', label: 'Images' },
  { value: 'apple_vision', label: 'Apple Vision' },
] as const

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
let analysisStatus: AnalysisStatus = {
  is_black: null,
  upload_state: 'not_started',
  image_count: 0,
}
let settings: RelaySettings = {
  profile: 'general',
  profile_name: 'General',
  upload_mode: 'images',
  upload_mode_name: 'Images',
}
let ocrPreview: OCRFrame | null = null
let lastOCRPreviewUpdateAt = 0
let view: ViewKind = 'main'
let pickerIndex = 0
let scrollPosition = 0
let viewports = ['等待答案']
let pollTimer: number | undefined
let rendering: Promise<unknown> = Promise.resolve()
let stopped = false
let leftClickArmedUntil = 0

restoreState()

function requiredElement<T extends Element>(selector: string): T {
  const element = document.querySelector<T>(selector)
  if (!element) throw new Error(`Missing companion element: ${selector}`)
  return element
}

function menu(): MenuContainerProperty {
  return new MenuContainerProperty({
    menuItems: [
      new MenuItemProperty({ itemName: 'Select Model', itemID: 1 }),
      new MenuItemProperty({ itemName: 'Select Upload Mode', itemID: 2 }),
      new MenuItemProperty({ itemName: '向上滚动', itemID: 3 }),
      new MenuItemProperty({ itemName: '向下滚动', itemID: 4 }),
      new MenuItemProperty({ itemName: '清空答案', itemID: 5 }),
      new MenuItemProperty({ itemName: '刷新', itemID: 6 }),
    ],
  })
}

function header(): string {
  return `${settings.profile_name} · ${settings.upload_mode_name} · v${APP_VERSION}`
}

function ocrLayout(frame: OCRFrame): string {
  const rows = 7
  const columns = 44
  const grid = Array.from({ length: rows }, () => Array<string>(columns).fill(' '))
  const blocks = [...frame.blocks].sort((left, right) => left.y - right.y || left.x - right.x)
  for (const block of blocks) {
    const row = Math.min(rows - 1, Math.max(0, Math.floor(block.y * rows)))
    const start = Math.min(columns - 1, Math.max(0, Math.floor(block.x * columns)))
    const available = columns - start
    const text = block.text.replace(/\s+/gu, ' ').trim().slice(0, available)
    for (let index = 0; index < text.length; index += 1) {
      const column = start + index
      if (grid[row][column] === ' ') grid[row][column] = text[index]
    }
  }
  return grid.map((row) => row.join('').trimEnd()).join('\n').trimEnd()
}

function pickerDocument(): string {
  const options = view === 'profile_picker' ? PROFILE_OPTIONS : UPLOAD_OPTIONS
  const title = view === 'profile_picker' ? 'Select Model' : 'Select Upload Mode'
  const lines = options.map((option, index) => `${index === pickerIndex ? '▶' : ' '} ${option.label}`)
  return `${title}\n${lines.join('\n')}\n\n上下滑动选择 · 单击确认`
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
  if (view !== 'main') return pickerDocument()

  const cameraLine = cameraStatus.connected
    ? `相机：已连接${typeof cameraStatus.battery_level === 'number' ? ` · 电量 ${cameraStatus.battery_level}%` : ''}`
    : `相机：${cameraStatus.state === 'connecting' ? '连接中' : cameraStatus.state === 'reconnecting' ? '正在重连' : '未连接'}`

  const showingUploadStatus = analysisStatus.upload_state !== 'not_started'
    || (analysisStatus.is_black === true && analysisStatus.image_count > 0)
  if (showingUploadStatus) {
    const isBlack = typeof analysisStatus.is_black === 'boolean'
      ? (analysisStatus.is_black ? '是' : '否')
      : '待检测'
    const hasStarted = showingUploadStatus ? '是' : '否'
    const hasFinished = analysisStatus.upload_state === 'success'
      ? '是（成功）'
      : analysisStatus.upload_state === 'failed' ? '是（失败）' : '否'
    return `${cameraLine}\n\n是否黑屏：${isBlack}\n开始上传：${hasStarted}\n结束上传：${hasFinished}\n共计图片：${analysisStatus.image_count} 张`
  }

  if (analysisStatus.is_black === false && analysisStatus.image_count > 0) {
    const preview = ocrPreview && ocrPreview.blocks.length > 0
      ? ocrLayout(ocrPreview)
      : 'Apple Vision 正在识别本张截图…'
    return `共计图片：${analysisStatus.image_count} 张\n\n${preview}`
  }

  if (questions.length === 0) {
    const isBlack = typeof analysisStatus.is_black === 'boolean'
      ? (analysisStatus.is_black ? '是' : '否')
      : '待检测'
    return `${cameraLine}\n\n是否黑屏：${isBlack}\n开始上传：否\n结束上传：否\n共计图片：${analysisStatus.image_count} 张`
  }

  const answers = batchGroups().map((batch, batchIndex) => {
    const quickAnswers = batch.map((question) =>
      `${question.question_number}. ${brief(question.question)} → ${question.answer}`,
    ).join('\n')

    const fullAnswers = batch.map((question) => {
      const uncertain = question.certainty === 'uncertain' ? '（识别可能不完整）' : ''
      return `第 ${question.question_number} 题${uncertain}\n${question.question}\n具体答案：${question.answer}`
    }).join('\n\n────────\n\n')

    return `第 ${batchIndex + 1} 批 · 答案速览\n\n${quickAnswers}\n\n第 ${batchIndex + 1} 批 · 完整题目与具体答案\n\n${fullAnswers}`
  }).join('\n\n════════\n\n')
  return answers
}

function shouldShowHeader(): boolean {
  if (view !== 'main' || questions.length === 0) return true
  return analysisStatus.upload_state !== 'not_started' || analysisStatus.image_count > 0
}

function updateViewports(): void {
  const reservedHeaderHeight = shouldShowHeader() ? HEADER_HEIGHT : 0
  viewports = paginate(answerDocument(), {
    width: BODY_WIDTH - BODY_PADDING * 2,
    height: BODY_HEIGHT - BODY_PADDING * 2 - reservedHeaderHeight,
  })
  scrollPosition = Math.min(Math.max(0, scrollPosition), viewports.length - 1)
}

async function render(): Promise<void> {
  updateViewports()
  const viewport = viewports[scrollPosition] ?? '等待答案'
  const body = shouldShowHeader() ? `${header()}\n${viewport}` : viewport
  rendering = rendering.then(async () => {
    await bridge.textContainerUpgrade(new TextContainerUpgrade({
      containerID: 1,
      containerName: 'answerScroll',
      content: body,
      textColor: 4,
    }))
  })
  await rendering
  mirrorElement.textContent = body
  questionCountElement.textContent = `${questions.length} 道题`
  pageCountElement.textContent = '连续滚动'
  persistState()
}

function scroll(offset: number): void {
  if (view !== 'main') {
    const length = view === 'profile_picker' ? PROFILE_OPTIONS.length : UPLOAD_OPTIONS.length
    pickerIndex = (pickerIndex + offset + length) % length
    void render()
    return
  }
  updateViewports()
  scrollPosition = Math.min(viewports.length - 1, Math.max(0, scrollPosition + offset))
  void render()
}

function clearAnswers(): void {
  questions = []
  scrollPosition = 0
  void render()
}

async function selectSetting(): Promise<void> {
  if (view === 'profile_picker') {
    const option = PROFILE_OPTIONS[pickerIndex]
    const response = await fetch(
      `${RELAY_BASE}/api/settings/profile?value=${encodeURIComponent(option.value)}`,
      { method: 'POST', signal: AbortSignal.timeout(2_500) },
    )
    if (!response.ok) throw new Error(`Profile update failed: HTTP ${response.status}`)
    settings = { ...settings, profile: option.value, profile_name: option.label }
  } else if (view === 'upload_picker') {
    const option = UPLOAD_OPTIONS[pickerIndex]
    const response = await fetch(
      `${RELAY_BASE}/api/settings/upload-mode?value=${encodeURIComponent(option.value)}`,
      { method: 'POST', signal: AbortSignal.timeout(2_500) },
    )
    if (!response.ok) throw new Error(`Upload mode update failed: HTTP ${response.status}`)
    settings = { ...settings, upload_mode: option.value, upload_mode_name: option.label }
  }
  view = 'main'
  scrollPosition = 0
  await render()
}

function eventTypeOf(envelope?: { eventType?: OsEventTypeList }): OsEventTypeList | null {
  if (!envelope) return null
  return envelope.eventType ?? OsEventTypeList.CLICK_EVENT
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
    if (view !== 'main') {
      await selectSetting()
      return
    }
    if (isLeft(source)) leftClickArmedUntil = Date.now() + ARM_WINDOW_MS
    scroll(1)
    return
  }
  if (type === OsEventTypeList.LONG_PRESS_EVENT) {
    if (isLeft(source) && Date.now() <= leftClickArmedUntil) {
      leftClickArmedUntil = 0
      clearAnswers()
    }
    return
  }
  if (type === OsEventTypeList.SCROLL_BOTTOM_EVENT) {
    scroll(1)
    return
  }
  if (type === OsEventTypeList.SCROLL_TOP_EVENT) {
    scroll(-1)
    return
  }
  if (type === OsEventTypeList.DOUBLE_CLICK_EVENT && (isRight(source) || source === null)) {
    if (view !== 'main') {
      view = 'main'
      scrollPosition = 0
      await render()
      return
    }
    await bridge.shutDownPageContainer(1)
  }
}

function isRelayEnvelope(value: unknown): value is RelayEnvelope {
  if (!value || typeof value !== 'object') return false
  const candidate = value as Partial<RelayEnvelope>
  return typeof candidate.session_id === 'string'
    && typeof candidate.latest_sequence === 'number'
    && !!candidate.camera
    && typeof candidate.camera.connected === 'boolean'
    && !!candidate.analysis
    && typeof candidate.analysis.upload_state === 'string'
    && typeof candidate.analysis.image_count === 'number'
    && !!candidate.settings
    && typeof candidate.settings.profile === 'string'
    && typeof candidate.settings.upload_mode === 'string'
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
    const analysisChanged = JSON.stringify(analysisStatus) !== JSON.stringify(payload.analysis)
    const settingsChanged = JSON.stringify(settings) !== JSON.stringify(payload.settings)
    const incomingOCRPreview = payload.ocr_preview ?? null
    let ocrChanged = false
    cameraStatus = payload.camera
    analysisStatus = payload.analysis
    settings = payload.settings
    if (incomingOCRPreview === null) {
      if (ocrPreview !== null) {
        ocrPreview = null
        ocrChanged = true
      }
      lastOCRPreviewUpdateAt = 0
    } else if (JSON.stringify(ocrPreview) !== JSON.stringify(incomingOCRPreview)) {
      const now = Date.now()
      if (ocrPreview === null || now - lastOCRPreviewUpdateAt >= OCR_PREVIEW_INTERVAL_MS) {
        ocrPreview = incomingOCRPreview
        lastOCRPreviewUpdateAt = now
        ocrChanged = true
      }
    }

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
      } else if (cameraChanged || analysisChanged || settingsChanged || ocrChanged) {
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
    containerTotalNum: 1,
    textObject: [
      new TextContainerProperty({
        xPosition: 0, yPosition: 0, width: BODY_WIDTH, height: BODY_HEIGHT,
        borderWidth: 0, paddingLength: BODY_PADDING,
        containerID: 1, containerName: 'answerScroll',
        content: viewports[scrollPosition], textColor: 4, isEventCapture: 1,
      }),
    ],
    menuObject: menu(),
  }))
  if (created !== 0) throw new Error(`Even G2 page creation failed: ${String(created)}`)

  const unsubscribe = bridge.onEvenHubEvent((event) => {
    const menuItem = event.menuItemClickEvent?.itemID
    if (menuItem !== undefined) {
      switch (menuItem) {
      case 1:
        view = 'profile_picker'
        pickerIndex = Math.max(0, PROFILE_OPTIONS.findIndex((option) => option.value === settings.profile))
        scrollPosition = 0
        void render()
        break
      case 2:
        view = 'upload_picker'
        pickerIndex = Math.max(0, UPLOAD_OPTIONS.findIndex((option) => option.value === settings.upload_mode))
        scrollPosition = 0
        void render()
        break
      case 3: scroll(-1); break
      case 4: scroll(1); break
      case 5: clearAnswers(); break
      case 6: void poll(); break
      default: break
      }
      return
    }

    const envelope = event.sysEvent ?? event.textEvent ?? event.listEvent
    const type = eventTypeOf(envelope)
    if (type !== null) void handleGesture(type, eventSourceOf(event.sysEvent))

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
