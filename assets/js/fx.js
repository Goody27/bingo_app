// ビンゴの演出まわり（音・紙吹雪・番号の抽選アニメーション）。
//
// サーバは「何が起きたか」（fx:drawn / fx:bingo / fx:reach ...）だけを送ってくる。
// それをどう派手に見せるかはこのファイルの責務で、ドメイン側は一切知らない。

const REDUCED_MOTION = window.matchMedia("(prefers-reduced-motion: reduce)").matches
const LETTERS = ["B", "I", "N", "G", "O"]

// ---------------------------------------------------------------------------
// 効果音
//
// 音声ファイルを持たず Web Audio API で合成する。
// アセットの追加もダウンロードも要らず、オフラインでも鳴るため。
// ---------------------------------------------------------------------------
class SoundKit {
  constructor() {
    this.ctx = null
    this.on = window.localStorage.getItem("bingo:sound") !== "off"
  }

  // ブラウザは操作なしの自動再生を止めるので、最初のクリックで初期化する
  unlock() {
    if (!this.ctx) {
      const AudioCtx = window.AudioContext || window.webkitAudioContext
      if (!AudioCtx) return
      this.ctx = new AudioCtx()
    }
    if (this.ctx.state === "suspended") this.ctx.resume()
  }

  toggle() {
    this.on = !this.on
    window.localStorage.setItem("bingo:sound", this.on ? "on" : "off")
    if (this.on) {
      this.unlock()
      this.tone(880, {dur: 0.12, type: "triangle"})
    }
    return this.on
  }

  tone(freq, {at = 0, dur = 0.15, type = "sine", gain = 0.14, slide = null} = {}) {
    if (!this.on || !this.ctx) return
    const t0 = this.ctx.currentTime + at
    const osc = this.ctx.createOscillator()
    const amp = this.ctx.createGain()

    osc.type = type
    osc.frequency.setValueAtTime(freq, t0)
    if (slide) osc.frequency.exponentialRampToValueAtTime(slide, t0 + dur)

    // 矩形波をそのまま切ると耳障りなので、立ち上がりと減衰を必ず付ける
    amp.gain.setValueAtTime(0.0001, t0)
    amp.gain.exponentialRampToValueAtTime(gain, t0 + 0.012)
    amp.gain.exponentialRampToValueAtTime(0.0001, t0 + dur)

    osc.connect(amp).connect(this.ctx.destination)
    osc.start(t0)
    osc.stop(t0 + dur + 0.03)
  }

  tick() { this.tone(1400, {dur: 0.025, type: "square", gain: 0.05}) }
  start() { this.tone(392, {dur: 0.5, type: "triangle", slide: 1046, gain: 0.12}) }
  pop() { this.tone(740, {dur: 0.09, type: "sine", gain: 0.08}) }

  reveal(mine) {
    this.tone(523, {dur: 0.1, type: "triangle"})
    this.tone(784, {at: 0.08, dur: 0.32, type: "triangle", gain: 0.16})
    // 自分のカードに載っていたら、もう一音重ねて「当たった感」を出す
    if (mine) this.tone(1046, {at: 0.16, dur: 0.3, type: "sine", gain: 0.12})
  }

  reach() {
    this.tone(880, {dur: 0.09, type: "square", gain: 0.1})
    this.tone(1174, {at: 0.11, dur: 0.28, type: "square", gain: 0.1})
  }

  fanfare() {
    const notes = [523, 659, 784, 1046]
    notes.forEach((f, i) => this.tone(f, {at: i * 0.09, dur: 0.22, type: "triangle", gain: 0.16}))
    this.tone(1318, {at: 0.42, dur: 0.7, type: "triangle", gain: 0.18})
    this.tone(1046, {at: 0.42, dur: 0.7, type: "sine", gain: 0.1})
  }

  finish() {
    this.tone(659, {dur: 0.18, type: "triangle"})
    this.tone(523, {at: 0.16, dur: 0.45, type: "triangle"})
  }
}

// ---------------------------------------------------------------------------
// 紙吹雪
// ---------------------------------------------------------------------------
const COLORS = ["#f59e0b", "#10b981", "#3b82f6", "#ef4444", "#a855f7", "#ffffff"]

function burstConfetti(canvas, count = 170) {
  if (REDUCED_MOTION) return

  const ctx = canvas.getContext("2d")
  const dpr = window.devicePixelRatio || 1
  canvas.width = window.innerWidth * dpr
  canvas.height = window.innerHeight * dpr
  ctx.scale(dpr, dpr)

  const w = window.innerWidth
  const h = window.innerHeight

  const pieces = Array.from({length: count}, () => ({
    x: w / 2 + (Math.random() - 0.5) * w * 0.6,
    y: h * 0.35 + (Math.random() - 0.5) * 80,
    vx: (Math.random() - 0.5) * 13,
    vy: Math.random() * -13 - 4,
    size: Math.random() * 8 + 4,
    rot: Math.random() * Math.PI,
    spin: (Math.random() - 0.5) * 0.3,
    color: COLORS[Math.floor(Math.random() * COLORS.length)]
  }))

  canvas.classList.add("fx-on")
  const started = performance.now()

  const frame = (now) => {
    const elapsed = now - started
    ctx.clearRect(0, 0, w, h)

    pieces.forEach((p) => {
      p.vy += 0.32
      p.vx *= 0.994
      p.x += p.vx
      p.y += p.vy
      p.rot += p.spin

      ctx.save()
      ctx.translate(p.x, p.y)
      ctx.rotate(p.rot)
      ctx.globalAlpha = Math.max(0, 1 - elapsed / 3600)
      ctx.fillStyle = p.color
      ctx.fillRect(-p.size / 2, -p.size / 2, p.size, p.size * 0.6)
      ctx.restore()
    })

    if (elapsed < 3600) {
      requestAnimationFrame(frame)
    } else {
      ctx.clearRect(0, 0, w, h)
      canvas.classList.remove("fx-on")
    }
  }

  requestAnimationFrame(frame)
}

// ---------------------------------------------------------------------------
// LiveView フック
// ---------------------------------------------------------------------------
const sound = new SoundKit()

function randomLabel() {
  const n = Math.floor(Math.random() * 75) + 1
  return LETTERS[Math.floor((n - 1) / 15)] + n
}

export const Effects = {
  mounted() {
    this.el.innerHTML = `
      <canvas class="fx-confetti"></canvas>
      <div class="fx-reveal"><span class="fx-reveal-text"></span></div>
      <div class="fx-banner"></div>
      <button class="fx-sound" type="button" aria-label="効果音の切り替え"></button>
    `

    this.canvas = this.el.querySelector(".fx-confetti")
    this.reveal = this.el.querySelector(".fx-reveal")
    this.revealText = this.el.querySelector(".fx-reveal-text")
    this.banner = this.el.querySelector(".fx-banner")
    this.soundButton = this.el.querySelector(".fx-sound")

    this.renderSoundButton()
    this.soundButton.addEventListener("click", () => {
      sound.toggle()
      this.renderSoundButton()
    })

    // 最初の操作で AudioContext を起こす（自動再生ブロック対策）
    this.unlock = () => sound.unlock()
    document.addEventListener("click", this.unlock, {once: true})
    document.addEventListener("touchstart", this.unlock, {once: true})

    this.handleEvent("fx:start", () => {
      sound.start()
      this.showBanner("抽選スタート！", "start")
    })

    this.handleEvent("fx:drawn", ({label, mine}) => this.spinTo(label, mine))
    this.handleEvent("fx:reach", () => {
      sound.reach()
      this.showBanner("リーチ！", "reach")
    })

    this.handleEvent("fx:bingo", ({name, rank, mine}) => {
      if (mine) {
        sound.fanfare()
        burstConfetti(this.canvas)
        this.showBanner(`BINGO! ${rank}着`, "bingo")
      } else {
        sound.pop()
        this.showBanner(`${name} さんがビンゴ（${rank}着）`, "other")
      }
    })

    this.handleEvent("fx:finish", () => {
      sound.finish()
      this.showBanner("ゲーム終了", "start")
    })
  },

  destroyed() {
    clearInterval(this.spinner)
    clearTimeout(this.bannerTimer)
    document.removeEventListener("click", this.unlock)
    document.removeEventListener("touchstart", this.unlock)
  },

  renderSoundButton() {
    this.soundButton.textContent = sound.on ? "🔊" : "🔇"
    this.soundButton.classList.toggle("fx-muted", !sound.on)
  },

  // ルーレット風に番号を回してから着地させる。
  // 実際の番号はサーバから届いた時点で確定しているので、これは純粋な見せ方。
  spinTo(label, mine) {
    clearInterval(this.spinner)
    this.reveal.classList.remove("fx-land", "fx-mine")
    this.reveal.classList.add("fx-visible")
    if (mine) this.reveal.classList.add("fx-mine")

    if (REDUCED_MOTION) {
      this.land(label, mine)
      return
    }

    let ticks = 0
    this.spinner = setInterval(() => {
      this.revealText.textContent = randomLabel()
      sound.tick()
      if (++ticks >= 13) {
        clearInterval(this.spinner)
        this.land(label, mine)
      }
    }, 55)
  },

  land(label, mine) {
    this.revealText.textContent = label
    this.reveal.classList.add("fx-land")
    sound.reveal(mine)

    clearTimeout(this.revealTimer)
    this.revealTimer = setTimeout(() => {
      this.reveal.classList.remove("fx-visible", "fx-land", "fx-mine")
    }, 1100)
  },

  showBanner(text, kind) {
    this.banner.textContent = text
    this.banner.className = `fx-banner fx-visible fx-${kind}`

    clearTimeout(this.bannerTimer)
    this.bannerTimer = setTimeout(() => {
      this.banner.className = "fx-banner"
    }, kind === "bingo" ? 3200 : 1800)
  }
}
