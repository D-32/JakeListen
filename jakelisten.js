#!/usr/bin/env node
import { spawn, spawnSync, execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  writeFileSync,
  statSync,
  unlinkSync,
} from "node:fs";
import { homedir } from "node:os";
import { request as httpsRequest } from "node:https";
import { join, basename, extname, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";

// ---------- version ----------
const VERSION = "0.6";

// ---------- paths & config ----------
const HOME = homedir();
const APP_DIR = join(HOME, "JakeListen");
const REC_DIR = join(APP_DIR, "recordings");
const CONFIG_DIR = join(HOME, ".jakelisten");
const CONFIG_PATH = join(CONFIG_DIR, "config.json");

// The system-audio capture helper lives next to this script (Node resolves the
// symlink in /usr/local/bin back to the real JakeListen folder).
const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const SYSCAP_BIN = join(SCRIPT_DIR, "jakelisten-syscap");
function syscapBin() {
  return existsSync(SYSCAP_BIN) ? SYSCAP_BIN : null;
}

const DEFAULT_CONFIG = {
  geminiApiKey: "",
  model: "gemini-3.5-flash", // summary model
  transcribeModel: "gemini-3.1-pro-preview", // transcription model (more accurate)
  userName: "", // your name — used to label your side of the call (optional)
  transcribeContext: "", // optional domain primer: names/jargon to spell correctly
  micDevice: "MacBook Air Microphone",
  slackRecipient: "", // default user/channel id, optional
  autoPostSlack: false, // true → post to slackRecipient without asking (for non-technical users)
};

// Long calls are split into chunks for accuracy/robustness; overlap keeps context.
const CHUNK_SEC = 600; // 10 min per chunk
const CHUNK_OVERLAP = 15; // seconds of overlap between chunks

function loadConfig() {
  let cfg = { ...DEFAULT_CONFIG };
  if (existsSync(CONFIG_PATH)) {
    try {
      cfg = { ...cfg, ...JSON.parse(readFileSync(CONFIG_PATH, "utf8")) };
    } catch {
      /* ignore malformed config */
    }
  }
  if (process.env.GEMINI_API_KEY) cfg.geminiApiKey = process.env.GEMINI_API_KEY;
  return cfg;
}

function saveConfig(cfg) {
  if (!existsSync(CONFIG_DIR)) mkdirSync(CONFIG_DIR, { recursive: true });
  writeFileSync(CONFIG_PATH, JSON.stringify(cfg, null, 2));
}

function ensureDirs() {
  for (const d of [APP_DIR, REC_DIR])
    if (!existsSync(d)) mkdirSync(d, { recursive: true });
}

// ---------- small utils ----------
const c = {
  dim: (s) => `\x1b[2m${s}\x1b[0m`,
  bold: (s) => `\x1b[1m${s}\x1b[0m`,
  green: (s) => `\x1b[32m${s}\x1b[0m`,
  yellow: (s) => `\x1b[33m${s}\x1b[0m`,
  red: (s) => `\x1b[31m${s}\x1b[0m`,
  cyan: (s) => `\x1b[36m${s}\x1b[0m`,
};

function log(...a) {
  console.log(...a);
}
function die(msg) {
  console.error(c.red("✗ " + msg));
  process.exit(1);
}

// "fetch failed" alone is useless — include the underlying cause when present.
function errMsg(e) {
  const cause = e?.cause?.code || e?.cause?.message;
  return cause ? `${e.message} (${cause})` : e.message;
}

function ask(question) {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((res) =>
    rl.question(question, (a) => {
      rl.close();
      res(a.trim());
    }),
  );
}

function timestamp() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}_${p(d.getHours())}-${p(d.getMinutes())}-${p(d.getSeconds())}`;
}

// ---------- device listing ----------
function listAudioDevices() {
  let out = "";
  try {
    execFileSync(
      "ffmpeg",
      ["-f", "avfoundation", "-list_devices", "true", "-i", ""],
      {
        stdio: ["ignore", "ignore", "pipe"],
      },
    );
  } catch (e) {
    out = e.stderr ? e.stderr.toString() : "";
  }
  const audio = [];
  let inAudio = false;
  for (const line of out.split("\n")) {
    if (line.includes("AVFoundation audio devices")) {
      inAudio = true;
      continue;
    }
    if (line.includes("AVFoundation video devices")) {
      inAudio = false;
      continue;
    }
    const m = line.match(/\[(\d+)\]\s+(.*?)\s*$/);
    if (inAudio && m) audio.push({ index: Number(m[1]), name: m[2] });
  }
  return audio;
}

function findDevice(devices, wanted) {
  // match by exact name, then substring (case-insensitive)
  const exact = devices.find((d) => d.name === wanted);
  if (exact) return exact;
  const sub = devices.find((d) =>
    d.name.toLowerCase().includes(wanted.toLowerCase()),
  );
  return sub || null;
}

// ---------- recording ----------
// Band-limit everything to the voice range. The mic gets NO loudness
// normalization: loudnorm amplifies the noise floor during long silences into
// speech-like mush (breathing, speaker bleed) that makes the transcription
// model hallucinate repeated sentences. System audio is a clean digital
// signal, so loudnorm is safe there and evens out per-app volume differences.
const BAND_FILTER = "highpass=f=80,lowpass=f=8000";
const MIC_FILTER = BAND_FILTER;
const CLEAN_FILTER = `${BAND_FILTER},loudnorm`;

// Resample/clean an arbitrary audio file into a 16 kHz mono PCM WAV (the ASR format).
function toCleanWav(inFile, outFile) {
  execFileSync(
    "ffmpeg",
    [
      "-y",
      "-i",
      inFile,
      "-filter_complex",
      `[0:a]${CLEAN_FILTER}[a]`,
      "-map",
      "[a]",
      "-ac",
      "1",
      "-ar",
      "16000",
      "-c:a",
      "pcm_s16le",
      outFile,
    ],
    { stdio: "ignore" },
  );
}

function recordCall(cfg) {
  ensureDirs();
  const devices = listAudioDevices();
  const mic = findDevice(devices, cfg.micDevice);

  if (!mic)
    die(`Mic device "${cfg.micDevice}" not found. Run: jakelisten devices`);

  // Two separate channels → deterministic diarization (no mono-mix guessing):
  //   • mic  → captured by ffmpeg/avfoundation        ("me")
  //   • call → captured by the Core Audio taps helper ("others"), no BlackHole
  const syscap = syscapBin();
  const ts = timestamp();
  const meFile = join(REC_DIR, `call-${ts}.me.wav`);
  const othersFile = join(REC_DIR, `call-${ts}.others.wav`);
  const othersRaw = join(REC_DIR, `call-${ts}.others.caf`); // native tap format

  // mic → cleaned 16 kHz mono WAV
  const micArgs = [
    "-y",
    "-f",
    "avfoundation",
    "-i",
    `:${mic.index}`,
    "-filter_complex",
    `[0:a]${MIC_FILTER}[me]`,
    "-map",
    "[me]",
    "-ac",
    "1",
    "-ar",
    "16000",
    "-c:a",
    "pcm_s16le",
    meFile,
  ];

  log("");
  log(c.bold("🐕 JakeListen") + c.dim(` v${VERSION} — recording...`));
  log(c.dim(`  mic:      [${mic.index}] ${mic.name}`));
  if (syscap) log(c.dim(`  call:     system audio (Core Audio tap)`));
  else
    log(
      c.yellow(
        "  call:     (none) — system-audio helper not built; recording MIC ONLY.",
      ),
    );
  log(c.dim(`  output:   ${meFile}`));
  if (syscap) log(c.dim(`            ${othersFile}`));
  log("");
  log(
    c.green("● REC") + "  Press " + c.bold("Enter") + " to stop and process.",
  );

  const ff = spawn("ffmpeg", micArgs, { stdio: ["pipe", "ignore", "ignore"] });
  // Surface the helper's status/warnings; capture stderr so we can detect silence.
  let scStderr = "";
  const sc = syscap
    ? spawn(syscap, [othersRaw], { stdio: ["pipe", "ignore", "pipe"] })
    : null;
  if (sc) sc.stderr.on("data", (d) => (scStderr += d.toString()));

  return new Promise((resolve, reject) => {
    let stopped = false;
    let ffDone = false;
    let scDone = !sc;

    const finish = () => {
      if (!ffDone || !scDone) return;
      if (!existsSync(meFile) || statSync(meFile).size < 1024) {
        return reject(
          new Error(
            "Recording produced no audio. Check mic permissions (System Settings → Privacy → Microphone → Terminal).",
          ),
        );
      }
      const secs = (statSync(meFile).size / (16000 * 2)).toFixed(0); // 16kHz s16le mono

      // Post-process the captured system audio into the same 16 kHz mono WAV.
      let haveOthers = false;
      if (sc && existsSync(othersRaw) && statSync(othersRaw).size > 1024) {
        try {
          toCleanWav(othersRaw, othersFile);
          haveOthers = statSync(othersFile).size > 1024;
        } catch {
          /* leave haveOthers false */
        }
      }
      try {
        if (existsSync(othersRaw)) unlinkSync(othersRaw);
      } catch {
        /* noop */
      }

      log("");
      log(
        c.green("■ Stopped.") +
          c.dim(
            `  ~${secs}s, saved ${basename(meFile)}${haveOthers ? " (+ call audio)" : ""}`,
          ),
      );
      if (sc && !haveOthers) {
        log(
          c.yellow(
            "⚠ No system audio captured — transcribing your mic only. " +
              "Run `jakelisten permission` once and click Allow, then re-record.",
          ),
        );
        if (scStderr.trim())
          log(c.dim("  " + scStderr.trim().split("\n").pop()));
      }
      resolve({ meFile, othersFile: haveOthers ? othersFile : null });
    };

    const stop = () => {
      if (stopped) return;
      stopped = true;
      // 'q' tells ffmpeg to finish writing the file cleanly; the helper stops on 'q'/SIGTERM.
      try {
        ff.stdin.write("q");
      } catch {
        /* noop */
      }
      try {
        if (sc) sc.stdin.write("q");
      } catch {
        /* noop */
      }
      setTimeout(() => {
        try {
          ff.kill("SIGTERM");
        } catch {
          /* noop */
        }
        try {
          if (sc) sc.kill("SIGTERM");
        } catch {
          /* noop */
        }
      }, 2000);
    };

    const rl = createInterface({
      input: process.stdin,
      output: process.stdout,
    });
    rl.on("line", () => {
      rl.close();
      stop();
    });
    process.on("SIGINT", () => {
      rl.close();
      stop();
    });

    ff.on("error", (e) =>
      reject(new Error("ffmpeg failed to start: " + e.message)),
    );
    ff.on("close", () => {
      ffDone = true;
      finish();
    });
    if (sc) {
      sc.on("error", () => {
        scDone = true;
        finish();
      });
      sc.on("close", () => {
        scDone = true;
        finish();
      });
    }
  });
}

// ---------- Gemini ----------
const GEMINI_BASE = "https://generativelanguage.googleapis.com";

async function geminiUploadFile(cfg, filePath) {
  const bytes = readFileSync(filePath);
  const mime = mimeFor(filePath);
  // 1) start resumable upload
  const startRes = await fetch(
    `${GEMINI_BASE}/upload/v1beta/files?key=${cfg.geminiApiKey}`,
    {
      method: "POST",
      headers: {
        "X-Goog-Upload-Protocol": "resumable",
        "X-Goog-Upload-Command": "start",
        "X-Goog-Upload-Header-Content-Length": String(bytes.length),
        "X-Goog-Upload-Header-Content-Type": mime,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ file: { display_name: basename(filePath) } }),
    },
  );
  if (!startRes.ok)
    throw new Error(
      `Gemini upload start failed: ${startRes.status} ${await startRes.text()}`,
    );
  const uploadUrl = startRes.headers.get("x-goog-upload-url");
  if (!uploadUrl) throw new Error("Gemini did not return an upload URL");

  // 2) upload bytes + finalize
  const upRes = await fetch(uploadUrl, {
    method: "POST",
    headers: {
      "Content-Length": String(bytes.length),
      "X-Goog-Upload-Offset": "0",
      "X-Goog-Upload-Command": "upload, finalize",
    },
    body: bytes,
  });
  if (!upRes.ok)
    throw new Error(
      `Gemini upload failed: ${upRes.status} ${await upRes.text()}`,
    );
  const info = await upRes.json();
  let file = info.file;

  // 3) wait until ACTIVE
  while (file.state === "PROCESSING") {
    await new Promise((r) => setTimeout(r, 1500));
    const r = await fetch(
      `${GEMINI_BASE}/v1beta/${file.name}?key=${cfg.geminiApiKey}`,
    );
    file = await r.json();
  }
  if (file.state !== "ACTIVE")
    throw new Error(`Uploaded file not active (state=${file.state})`);
  return file; // has .uri and .mimeType
}

// Long transcriptions regularly exceed 5 minutes; Node's built-in fetch
// (undici) aborts after 300s waiting for response headers, so the generate
// call uses node:https with a more generous idle timeout (a hung request is
// destroyed and handled by the per-chunk retry).
const GENERATE_IDLE_TIMEOUT_MS = 10 * 60 * 1000;

function httpsPostJson(url, bodyObj) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify(bodyObj);
    const u = new URL(url);
    const req = httpsRequest(
      {
        hostname: u.hostname,
        path: u.pathname + u.search,
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Content-Length": Buffer.byteLength(body),
        },
      },
      (res) => {
        let data = "";
        res.on("data", (d) => (data += d));
        res.on("end", () => resolve({ status: res.statusCode, text: data }));
      },
    );
    req.setTimeout(GENERATE_IDLE_TIMEOUT_MS, () => {
      req.destroy(
        new Error(
          `no response after ${GENERATE_IDLE_TIMEOUT_MS / 60000} minutes`,
        ),
      );
    });
    req.on("error", reject);
    req.end(body);
  });
}

async function geminiGenerate(cfg, parts, opts = {}) {
  const model = opts.model || cfg.model;
  const body = { contents: [{ role: "user", parts }] };
  if (opts.temperature != null) {
    body.generationConfig = { temperature: opts.temperature };
  }
  const res = await httpsPostJson(
    `${GEMINI_BASE}/v1beta/models/${model}:generateContent?key=${cfg.geminiApiKey}`,
    body,
  );
  if (res.status !== 200)
    throw new Error(`Gemini generate failed: ${res.status} ${res.text}`);
  const data = JSON.parse(res.text);
  const text =
    data?.candidates?.[0]?.content?.parts?.map((p) => p.text || "").join("") ||
    "";
  // Transcription prompts say "if nothing is said, output nothing" — a silent
  // chunk legitimately yields an empty response.
  if (!text && !opts.allowEmpty)
    throw new Error("Gemini returned empty response");
  return text.trim();
}

function mimeFor(filePath) {
  const ext = extname(filePath).toLowerCase();
  return (
    {
      ".mp3": "audio/mp3",
      ".wav": "audio/wav",
      ".m4a": "audio/mp4",
      ".aac": "audio/aac",
      ".flac": "audio/flac",
      ".ogg": "audio/ogg",
    }[ext] || "audio/mp3"
  );
}

// ---------- transcription pipeline ----------

function getDuration(file) {
  try {
    const out = execFileSync(
      "ffprobe",
      [
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "default=nw=1:nk=1",
        file,
      ],
      { stdio: ["ignore", "pipe", "ignore"] },
    )
      .toString()
      .trim();
    const d = parseFloat(out);
    return isFinite(d) ? d : 0;
  } catch {
    return 0;
  }
}

// Seconds of audio above the silence floor. Used to skip chunks with nothing
// in them — uploading pure silence wastes ~5 minutes of model time and is what
// triggers hallucination loops in the first place.
function speechSeconds(file) {
  const dur = getDuration(file);
  if (!dur) return 0;
  const r = spawnSync(
    "ffmpeg",
    [
      "-hide_banner",
      "-i",
      file,
      "-af",
      "silencedetect=n=-35dB:d=2",
      "-f",
      "null",
      "-",
    ],
    { encoding: "utf8" },
  );
  const out = r.stderr || "";
  let silence = 0;
  let cur = null;
  for (const [, kind, t] of out.matchAll(/silence_(start|end): (-?[\d.]+)/g)) {
    if (kind === "start") cur = Math.max(0, parseFloat(t));
    else if (cur != null) {
      silence += parseFloat(t) - cur;
      cur = null;
    }
  }
  if (cur != null) silence += dur - cur;
  return Math.max(0, dur - silence);
}

// Split a long recording into overlapping chunks for accuracy + robustness.
// Returns [{ path, offsetSec, index, temp }]. Short files yield one passthrough chunk.
function splitIntoChunks(file) {
  const dur = getDuration(file);
  if (!dur || dur <= CHUNK_SEC) {
    return [{ path: file, offsetSec: 0, index: 0, temp: false }];
  }
  const step = CHUNK_SEC - CHUNK_OVERLAP;
  const chunks = [];
  let i = 0;
  for (let start = 0; start < dur; start += step) {
    const out = file.replace(/\.wav$/i, `.chunk${i}.wav`);
    execFileSync(
      "ffmpeg",
      [
        "-y",
        "-ss",
        String(start),
        "-i",
        file,
        "-t",
        String(CHUNK_SEC),
        "-ac",
        "1",
        "-ar",
        "16000",
        "-c:a",
        "pcm_s16le",
        out,
      ],
      { stdio: "ignore" },
    );
    chunks.push({ path: out, offsetSec: start, index: i, temp: true });
    i++;
    if (start + CHUNK_SEC >= dur) break;
  }
  return chunks;
}

// Parse model output lines of the form "[mm:ss] Label: text" (or "[h:mm:ss]").
function parseUtterances(text) {
  const out = [];
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    const m = line.match(/^\[(\d{1,2}):(\d{2})(?::(\d{2}))?\]\s*(.*)$/);
    if (!m) continue;
    const sec =
      m[3] != null ? +m[1] * 3600 + +m[2] * 60 + +m[3] : +m[1] * 60 + +m[2];
    const rest = m[4];
    const ci = rest.indexOf(":");
    let label = "Speaker";
    let txt = rest;
    if (ci > 0 && ci <= 40) {
      label = rest.slice(0, ci).trim();
      txt = rest.slice(ci + 1).trim();
    }
    if (txt) out.push({ sec, label, text: txt });
  }
  return out;
}

function promptFor(mode, cfg) {
  const ctx = cfg.transcribeContext
    ? `\n\nDomain context (use it to spell names and jargon correctly):\n${cfg.transcribeContext}`
    : "";
  // Label for my own side of the call. With a configured name we get a clearer
  // "Me (Name)" label; otherwise fall back to a plain "Me".
  const meLabel = cfg.userName ? `Me (${cfg.userName})` : "Me";
  const iAm = cfg.userName ? ` I am ${cfg.userName}.` : "";
  const format =
    "Output ONLY transcript lines, one utterance per line, in EXACTLY this format:\n" +
    "[mm:ss] <Speaker>: <text>\n" +
    "where mm:ss is the start time of that utterance WITHIN THIS audio clip " +
    "(start a new line whenever the speaker changes or after a natural pause). " +
    "Transcribe verbatim. Do not add commentary, headers, or summaries.";
  if (mode === "me") {
    return (
      "This is ONE channel of a recorded call: only my own microphone." +
      iAm +
      ` Transcribe everything I say, verbatim. Always use the speaker label '${meLabel}'. ` +
      "If I say nothing, output nothing.\n\n" +
      format +
      ctx
    );
  }
  if (mode === "others") {
    return (
      "This is ONE channel of a recorded call: the combined audio of the OTHER participants " +
      "(everyone except me). Transcribe verbatim and diarize by voice — identify each distinct " +
      "speaker. If a speaker is named or addressed by name, use that name; otherwise label them " +
      "'Speaker 1', 'Speaker 2', etc., consistently throughout. Do NOT label anyone 'Me'.\n\n" +
      format +
      ctx
    );
  }
  // mixed: a single mono file (e.g. an imported recording)
  return (
    "This is a recording of a video call with MULTIPLE participants. " +
    "Transcribe verbatim and diarize by voice. If a speaker is named or addressed by name, use that " +
    "name; otherwise label them 'Speaker 1', 'Speaker 2', etc., consistently. " +
    `Label my own voice as '${meLabel}' where you can tell.\n\n` +
    format +
    ctx
  );
}

// Transcribe one audio file end-to-end: chunk → upload → transcribe → parse →
// offset timestamps → dedupe the overlap region. Returns sorted utterances.
// Each chunk is retried a few times so a transient network blip doesn't sink
// a long call (the recording stays on disk either way — see `process`).
// Chunks are transcribed concurrently — each one takes Gemini ~5 minutes, so
// serial processing of an hour-long call would take over an hour.
const CHUNK_TRIES = 3;
const CHUNK_PARALLEL = 3;

async function transcribeChunk(cfg, ch, mode, span) {
  for (let attempt = 1; ; attempt++) {
    try {
      log(c.dim(`↑ Uploading ${mode} channel${span}...`));
      const up = await geminiUploadFile(cfg, ch.path);
      log(c.dim(`✎ Transcribing ${mode} channel${span}...`));
      return await geminiGenerate(
        cfg,
        [
          { file_data: { mime_type: up.mimeType, file_uri: up.uri } },
          { text: promptFor(mode, cfg) },
        ],
        { model: cfg.transcribeModel, temperature: 0, allowEmpty: true },
      );
    } catch (e) {
      if (attempt >= CHUNK_TRIES) throw e;
      log(
        c.yellow(
          `  ✗ ${errMsg(e)} — retrying${span} (attempt ${attempt + 1}/${CHUNK_TRIES})...`,
        ),
      );
      await new Promise((r) => setTimeout(r, 3000 * attempt));
    }
  }
}

async function transcribeFile(cfg, file, mode) {
  const chunks = splitIntoChunks(file);
  const utts = [];
  let next = 0;
  const worker = async () => {
    while (next < chunks.length) {
      const ch = chunks[next++];
      const span =
        chunks.length > 1 ? ` [chunk ${ch.index + 1}/${chunks.length}]` : "";
      if (speechSeconds(ch.path) < 1) {
        log(c.dim(`∅ Skipping ${mode} channel${span} — silence.`));
        continue;
      }
      const text = await transcribeChunk(cfg, ch, mode, span);
      log(c.dim(`✓ Done ${mode} channel${span}.`));
      for (const u of parseUtterances(text)) {
        // The overlap region at the start of a chunk was already covered by the
        // previous chunk's tail — drop it so each moment is transcribed once.
        if (ch.index > 0 && u.sec < CHUNK_OVERLAP) continue;
        utts.push({ sec: u.sec + ch.offsetSec, label: u.label, text: u.text });
      }
    }
  };
  try {
    await Promise.all(
      Array.from({ length: Math.min(CHUNK_PARALLEL, chunks.length) }, worker),
    );
  } finally {
    for (const ch of chunks) {
      if (ch.temp) {
        try {
          unlinkSync(ch.path);
        } catch {
          /* noop */
        }
      }
    }
  }
  utts.sort((a, b) => a.sec - b.sec);
  return collapseLoops(utts);
}

// Even with the silence gate, the model can get stuck repeating one sentence
// over a quiet stretch. A run of 3+ consecutive identical utterances from the
// same speaker is never real speech — keep the first occurrence only.
function collapseLoops(utts) {
  const out = [];
  for (let i = 0; i < utts.length; ) {
    let j = i;
    while (
      j < utts.length &&
      utts[j].label === utts[i].label &&
      utts[j].text === utts[i].text
    )
      j++;
    const run = j - i;
    if (run >= 3) {
      out.push(utts[i]);
      log(
        c.dim(
          `  collapsed ${run}× repeated line ("${utts[i].text.slice(0, 60)}")`,
        ),
      );
    } else {
      for (let k = i; k < j; k++) out.push(utts[k]);
    }
    i = j;
  }
  return out;
}

function fmtTime(sec) {
  const s = Math.max(0, Math.round(sec));
  const p = (n) => String(n).padStart(2, "0");
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const ss = s % 60;
  return h > 0 ? `${h}:${p(m)}:${p(ss)}` : `${p(m)}:${p(ss)}`;
}

function renderTranscript(utts) {
  return utts
    .map((u) => `[${fmtTime(u.sec)}] ${u.label}: ${u.text}`)
    .join("\n");
}

async function buildTranscript(cfg, input) {
  if (!cfg.geminiApiKey) die("No Gemini API key. Run: jakelisten config");

  if (typeof input === "string") {
    // Single imported file: one mono stream, diarize as best we can.
    const utts = await transcribeFile(cfg, input, "mixed");
    return renderTranscript(utts);
  }

  // Recorded call: two channels transcribed independently (and concurrently),
  // then merged by time.
  const [meUtts, otherUtts] = await Promise.all([
    transcribeFile(cfg, input.meFile, "me"),
    input.othersFile
      ? transcribeFile(cfg, input.othersFile, "others")
      : Promise.resolve([]),
  ]);
  const all = [...meUtts, ...otherUtts].sort((a, b) => a.sec - b.sec);
  return renderTranscript(all);
}

async function summarize(cfg, transcript) {
  log(c.dim("✎ Summarizing..."));
  return geminiGenerate(cfg, [
    {
      text:
        "Below is a transcript of a multi-participant video call. Write a concise summary suitable for posting to a team Slack channel.\n\n" +
        "Format with these sections (use plain text, short lines):\n" +
        "*Summary* – 2-3 sentences.\n" +
        "*Participants* – who was on the call (names or speaker labels).\n" +
        "*Key points* – bullet list.\n" +
        "*Decisions* – bullet list (or 'none').\n" +
        "*Action items* – bullet list, with owner if known (or 'none').\n\n" +
        "Transcript:\n" +
        transcript,
    },
  ]);
}

// ---------- Slack ----------
function slackList(cursor) {
  const args = [
    "conversations",
    "list",
    "--types",
    "public_channel,private_channel",
    "--limit",
    "200",
  ];
  if (cursor) args.push("--cursor", cursor);
  try {
    return execFileSync("slackcli", args, {
      stdio: ["ignore", "pipe", "ignore"],
    }).toString();
  } catch (e) {
    return e.stdout ? e.stdout.toString() : "";
  }
}

// Resolve "#product" / "product" to a channel id, paginating through all channels.
function resolveSlackChannel(input) {
  const wanted = input.replace(/^#/, "").trim().toLowerCase();
  if (!wanted) return null;
  // already an id?
  if (/^[CGD][A-Z0-9]{6,}$/.test(input.trim()))
    return { id: input.trim(), name: input.trim() };

  const channels = [];
  let cursor = null;
  for (let page = 0; page < 25; page++) {
    const out = slackList(cursor);
    for (const m of out.matchAll(
      /#(\S+)\s+\(([A-Z0-9]+)\)(\s*\[archived\])?/g,
    )) {
      channels.push({ name: m[1], id: m[2], archived: !!m[3] });
    }
    const cm = out.match(/--cursor\s+"([^"]+)"/);
    if (cm) cursor = cm[1];
    else break;
  }
  const live = channels.filter((ch) => !ch.archived);
  const exact =
    live.find((ch) => ch.name.toLowerCase() === wanted) ||
    channels.find((ch) => ch.name.toLowerCase() === wanted);
  if (exact) return exact;
  const partial = live.filter((ch) => ch.name.toLowerCase().includes(wanted));
  if (partial.length === 1) return partial[0];
  return { ambiguous: partial.slice(0, 8) };
}

function postToSlack(recipient, message) {
  execFileSync(
    "slackcli",
    ["messages", "send", "--recipient-id", recipient, "--message", message],
    {
      stdio: ["ignore", "inherit", "inherit"],
    },
  );
}

// Scriptable Slack post: resolve a channel name/id and post a saved summary.
// Used by the GUI (which can't answer the interactive prompt) and handy on its own.
function cmdPost(cfg, file, channelInput) {
  if (!existsSync(file)) die(`File not found: ${file}`);
  if (!hasBin("slackcli")) die("slackcli not found.");
  const summary = readFileSync(file, "utf8");
  const displayName = basename(file).replace(/\.summary\.txt$/, "");
  const ch = resolveSlackChannel(channelInput);
  if (!ch || ch.ambiguous) die(`Could not resolve channel "${channelInput}".`);
  const header = `:dog: *Call summary* (${displayName})\n\n`;
  postToSlack(ch.id, header + summary);
  log(c.green(`✓ Posted to #${ch.name} (${ch.id}).`));
}

// ---------- flows ----------
async function processFile(cfg, input, { interactive = true } = {}) {
  // Derive a clean base name + display name from whichever input we got.
  const primary = typeof input === "string" ? input : input.meFile;
  const base = primary.replace(/(\.me)?\.[^.]+$/, "");
  const displayName = basename(base);
  const tPath = base + ".transcript.txt";
  const sPath = base + ".summary.txt";

  const transcript = await buildTranscript(cfg, input);
  // Save immediately — a summarize failure must not lose the transcript.
  writeFileSync(tPath, transcript);
  if (!transcript.trim()) {
    log(c.yellow("No speech detected — nothing to summarize."));
    return { transcript, summary: "", tPath, sPath: null };
  }
  const summary = await summarize(cfg, transcript);
  writeFileSync(sPath, summary);

  log("");
  log(c.bold("── Summary ──────────────────────────────"));
  log(summary);
  log(c.bold("─────────────────────────────────────────"));
  log("");
  log(c.dim(`transcript: ${tPath}`));
  log(c.dim(`summary:    ${sPath}`));
  log("");

  if (!interactive) return { transcript, summary, tPath, sPath };

  if (!hasBin("slackcli")) {
    log(c.yellow("slackcli not found — skipping Slack."));
    return { transcript, summary, tPath, sPath };
  }

  // Zero-decision mode (for non-technical users): post straight to the preset
  // channel without asking. Set autoPostSlack:true + slackRecipient in config.
  if (cfg.autoPostSlack && cfg.slackRecipient) {
    const ch = resolveSlackChannel(cfg.slackRecipient);
    const target =
      ch && ch.id ? ch : { id: cfg.slackRecipient, name: cfg.slackRecipient };
    const header = `:dog: *Call summary* (${displayName})\n\n`;
    try {
      postToSlack(target.id, header + summary);
      log(c.green(`✓ Posted to ${target.name}.`));
    } catch {
      log(
        c.yellow(`Could not post to ${target.name}. Transcript saved locally.`),
      );
    }
    return { transcript, summary, tPath, sPath };
  }

  const promptText = cfg.slackRecipient
    ? `Which Slack channel? (e.g. #product, Enter for ${cfg.slackRecipient}, or 'skip'): `
    : `Which Slack channel? (e.g. #product, blank to skip): `;

  while (true) {
    let input = (await ask(promptText)).trim();
    if (input.toLowerCase() === "skip")
      return { transcript, summary, tPath, sPath };
    if (!input) {
      if (cfg.slackRecipient) input = cfg.slackRecipient;
      else return { transcript, summary, tPath, sPath };
    }

    log(c.dim(`  resolving ${input}...`));
    const ch = resolveSlackChannel(input);
    if (!ch) {
      log(c.yellow("  empty input."));
      continue;
    }
    if (ch.ambiguous) {
      if (ch.ambiguous.length === 0)
        log(c.yellow(`  no channel matching "${input}". Try again.`));
      else {
        log(c.yellow("  multiple matches — be more specific:"));
        for (const m of ch.ambiguous) log(c.dim(`    #${m.name}`));
      }
      continue;
    }

    const header = `:dog: *Call summary* (${displayName})\n\n`;
    postToSlack(ch.id, header + summary);
    log(c.green(`✓ Posted to #${ch.name} (${ch.id}).`));
    return { transcript, summary, tPath, sPath };
  }
}

// Saved recordings (newest first), pairing each mic track with its call track.
function listRecordings() {
  ensureDirs();
  return readdirSync(REC_DIR)
    .filter((f) => f.endsWith(".me.wav"))
    .map((f) => {
      const meFile = join(REC_DIR, f);
      const base = meFile.replace(/\.me\.wav$/, "");
      const othersFile = base + ".others.wav";
      return {
        meFile,
        othersFile: existsSync(othersFile) ? othersFile : null,
        name: basename(base),
        mtime: statSync(meFile).mtimeMs,
        durationSec: getDuration(meFile),
        processed: existsSync(base + ".summary.txt"),
      };
    })
    .sort((a, b) => b.mtime - a.mtime);
}

// Re-run transcription/summary on an already-saved recording (e.g. after a
// network failure killed the first attempt).
async function cmdProcessRecent(cfg) {
  const recs = listRecordings().slice(0, 10);
  if (recs.length === 0)
    die(`No recordings found in ${REC_DIR}. Record one first.`);
  log("");
  log(c.bold("Recent recordings:"));
  recs.forEach((r, i) => {
    const notes = [fmtTime(r.durationSec)];
    if (!r.othersFile) notes.push("mic only");
    if (r.processed) notes.push("already processed");
    log(`  ${i + 1}) ${r.name} ${c.dim(`(${notes.join(", ")})`)}`);
  });
  const answer = await ask(`Which one? [1]: `);
  const n = answer ? parseInt(answer, 10) : 1;
  if (!Number.isInteger(n) || n < 1 || n > recs.length)
    die(`Invalid choice: ${answer}`);
  const r = recs[n - 1];
  await processFile(cfg, { meFile: r.meFile, othersFile: r.othersFile });
}

async function mainMenu(cfg) {
  log("");
  log(c.bold("🐕 JakeListen") + c.dim(` v${VERSION}`));
  log(`  1) Start recording`);
  log(`  2) Process a recent recording ${c.dim("(retry after a failure)")}`);
  log(`  3) Update config`);
  const answer = await ask("Choose [1]: ");
  if (answer === "2") {
    await cmdProcessRecent(cfg);
  } else if (answer === "3") {
    await cmdConfig();
  } else if (!answer || answer === "1") {
    const recorded = await recordCall(cfg);
    await processFile(cfg, recorded);
  } else {
    die(`Invalid choice: ${answer}`);
  }
}

// ---------- commands ----------
async function cmdDevices() {
  const devices = listAudioDevices();
  log(c.bold("Audio input devices (avfoundation):"));
  for (const d of devices) log(`  [${d.index}] ${d.name}`);
}

// First-run: if there's no config yet (or no key), collect the essentials
// interactively instead of shipping any hard-coded names/jargon. Mirrors how the
// Gemini key is requested.
async function ensureConfigured(cfg) {
  const firstRun = !existsSync(CONFIG_PATH);
  if (!firstRun && cfg.geminiApiKey) return cfg;

  log("");
  log(c.bold("🐕 First-time setup") + c.dim(" — a couple of quick questions."));
  if (!cfg.geminiApiKey) {
    log(
      c.dim("Get a free Gemini API key at https://aistudio.google.com/apikey"),
    );
    const key = await ask("Gemini API key: ");
    if (key) cfg.geminiApiKey = key;
  }
  if (firstRun) {
    const name = await ask(
      "Your name (used to label your side of the call, Enter to skip): ",
    );
    if (name) cfg.userName = name;
    log(
      c.dim(
        "Optional: names, jargon, or acronyms the transcriber should spell correctly.",
      ),
    );
    log(
      c.dim('  e.g. "Project Acme; teammates Sam, Priya; acronyms KPI, SLA."'),
    );
    const ctx = await ask("Domain context (Enter to skip): ");
    if (ctx) cfg.transcribeContext = ctx;
  }
  saveConfig(cfg);
  log(c.green("✓ Saved. Change these any time with `jakelisten config`."));
  log("");
  return cfg;
}

async function cmdConfig() {
  const cfg = loadConfig();
  log(c.bold("JakeListen config") + c.dim(` (${CONFIG_PATH})`));
  const key = await ask(
    `Gemini API key ${cfg.geminiApiKey ? "[keep current]" : ""}: `,
  );
  if (key) cfg.geminiApiKey = key;
  const tModel = await ask(`Transcription model [${cfg.transcribeModel}]: `);
  if (tModel) cfg.transcribeModel = tModel;
  const model = await ask(`Summary model [${cfg.model}]: `);
  if (model) cfg.model = model;
  const name = await ask(`Your name [${cfg.userName || "none"}]: `);
  if (name) cfg.userName = name;
  const ctx = await ask(
    `Domain context (names/jargon to spell correctly) [${cfg.transcribeContext ? "keep current" : "none"}]: `,
  );
  if (ctx) cfg.transcribeContext = ctx;
  const mic = await ask(`Mic device name [${cfg.micDevice}]: `);
  if (mic) cfg.micDevice = mic;
  const slack = await ask(
    `Default Slack recipient id [${cfg.slackRecipient || "none"}]: `,
  );
  if (slack) cfg.slackRecipient = slack;
  const auto = await ask(
    `Auto-post to that channel without asking? (y/N) [${cfg.autoPostSlack ? "yes" : "no"}]: `,
  );
  if (auto) cfg.autoPostSlack = /^y/i.test(auto);
  saveConfig(cfg);
  log(c.green("✓ Saved."));
}

function cmdSetup() {
  const cfg = loadConfig();
  const devices = listAudioDevices();
  const mic = findDevice(devices, cfg.micDevice);
  const syscap = syscapBin();
  log(c.bold("🐕 JakeListen setup check") + c.dim(` v${VERSION}`));
  log(
    `  Gemini key:        ${cfg.geminiApiKey ? c.green("set") : c.red("MISSING — run: jakelisten config")}`,
  );
  log(
    `  ffmpeg:            ${hasBin("ffmpeg") ? c.green("ok") : c.red("missing")}`,
  );
  log(
    `  slackcli:          ${hasBin("slackcli") ? c.green("ok") : c.yellow("missing (Slack posting disabled)")}`,
  );
  log(
    `  mic device:        ${mic ? c.green(`[${mic.index}] ${mic.name}`) : c.red(`not found (${cfg.micDevice})`)}`,
  );
  log(
    `  system audio:      ${syscap ? c.green("helper built (Core Audio tap — no BlackHole needed)") : c.yellow("helper not built — run: syscap/build.sh (records mic only without it)")}`,
  );
  if (syscap) {
    let status = "unknown";
    try {
      status = execFileSync(syscap, ["--check-permission"], {
        stdio: ["ignore", "pipe", "ignore"],
      })
        .toString()
        .trim();
    } catch {
      status = "denied";
    }
    log(
      `  audio permission:  ${status === "authorized" ? c.green("granted") : c.yellow("not granted — run: jakelisten permission")}`,
    );
  }
  log("");
  log(c.bold("That's it — no BlackHole, no Multi-Output Device."));
  log(
    c.dim(
      "  One-time: run `jakelisten permission` and click Allow. Then just `jakelisten` to record.",
    ),
  );
}

// One-time: trigger the macOS system-audio permission prompt.
function cmdPermission() {
  const syscap = syscapBin();
  if (!syscap) {
    log(
      c.yellow(
        "System-audio helper not built. Build it first:  cd syscap && ./build.sh",
      ),
    );
    return;
  }
  log(
    c.dim(
      "Requesting macOS system-audio recording permission — click Allow if a dialog appears...",
    ),
  );
  let status = "denied";
  try {
    status = execFileSync(syscap, ["--check-permission"], {
      stdio: ["ignore", "pipe", "inherit"],
    })
      .toString()
      .trim();
  } catch (e) {
    status = (e.stdout ? e.stdout.toString() : "").trim() || "denied";
  }
  if (status === "authorized") {
    log(c.green("✓ System audio recording is allowed. You're all set."));
  } else {
    log(
      c.yellow(
        "✗ Not granted. Open System Settings → Privacy & Security → Screen & System Audio Recording,",
      ),
    );
    log(
      c.yellow(
        "  enable your terminal app, then run `jakelisten permission` again.",
      ),
    );
  }
}

function hasBin(name) {
  try {
    execFileSync("which", [name], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

function help() {
  log(`${c.bold("🐕 JakeListen")} ${c.dim(`v${VERSION}`)} — record calls, transcribe + summarize with Gemini, post to Slack

${c.bold("Usage:")}
  jakelisten                Menu: start recording, or process a recent recording
  jakelisten record         Record a call, then transcribe + summarize + (optionally) post to Slack
  jakelisten record --no-slack  Record + process, but skip the Slack prompt (used by the GUI)
  jakelisten post <f> <ch>  Post a saved <summary-file> to Slack <channel> (name or id)
  jakelisten process        Pick a recent recording and (re)process it — retry after a failure
  jakelisten transcribe <f> Process an existing audio file
  jakelisten permission     Grant macOS system-audio recording (one-time, no BlackHole)
  jakelisten devices        List audio input devices
  jakelisten setup          Check configuration & devices
  jakelisten config         Set Gemini key, devices, default Slack recipient
  jakelisten help           Show this help`);
}

// ---------- main ----------
async function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  let cfg = loadConfig();
  try {
    switch (cmd) {
      case undefined:
        cfg = await ensureConfigured(cfg);
        await mainMenu(cfg);
        break;
      case "record": {
        cfg = await ensureConfigured(cfg);
        const recorded = await recordCall(cfg);
        await processFile(cfg, recorded, {
          interactive: !rest.includes("--no-slack"),
        });
        break;
      }
      case "post": {
        const [file, channel] = rest;
        if (!file || !channel)
          die("Usage: jakelisten post <summary-file> <channel>");
        cfg = await ensureConfigured(cfg);
        cmdPost(cfg, file, channel);
        break;
      }
      case "process":
        cfg = await ensureConfigured(cfg);
        await cmdProcessRecent(cfg);
        break;
      case "transcribe": {
        const f = rest[0];
        if (!f || !existsSync(f))
          die("Usage: jakelisten transcribe <audio-file>");
        cfg = await ensureConfigured(cfg);
        await processFile(cfg, f);
        break;
      }
      case "permission":
        cmdPermission();
        break;
      case "devices":
        await cmdDevices();
        break;
      case "config":
        await cmdConfig();
        break;
      case "setup":
        cmdSetup();
        break;
      case "version":
      case "-v":
      case "--version":
        log(`JakeListen v${VERSION}`);
        break;
      case "help":
      case "-h":
      case "--help":
        help();
        break;
      default:
        log(c.red(`Unknown command: ${cmd}`));
        help();
        process.exit(1);
    }
  } catch (e) {
    die(errMsg(e));
  }
  process.exit(0);
}

main();
