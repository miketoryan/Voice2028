use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use openless_core::{
    DictationStartOptions, DictationStopOptions, OpenLessBackend, ProviderSlot, SessionId,
};
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use std::sync::{OnceLock, Weak};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

const PORT: u16 = 14_557;
const PROTOCOL_VERSION: &str = "7";

static NATIVE_AUDIO_BRIDGE: OnceLock<Weak<KeyboardBridge>> = OnceLock::new();

unsafe extern "C" {
    fn OpenLessNativeAudioStart() -> bool;
    fn OpenLessNativeAudioStop();
}

fn start_native_audio() -> bool {
    // The symbol is supplied by OpenLessVoiceBootstrap.m in the iOS host.
    unsafe { OpenLessNativeAudioStart() }
}

fn stop_native_audio() {
    // The symbol is supplied by OpenLessVoiceBootstrap.m in the iOS host.
    unsafe { OpenLessNativeAudioStop() }
}

#[unsafe(no_mangle)]
pub extern "C" fn openless_ios_audio_pcm(bytes: *const u8, length: usize) {
    if bytes.is_null() || length == 0 || !length.is_multiple_of(2) {
        return;
    }
    let Some(bridge) = NATIVE_AUDIO_BRIDGE.get().and_then(Weak::upgrade) else {
        return;
    };
    let Some(session_id) = *bridge.session.lock() else {
        return;
    };
    // Swift owns this allocation for the duration of this synchronous call.
    let pcm = unsafe { std::slice::from_raw_parts(bytes, length) };
    if let Err(error) = bridge.backend.feed_external_pcm(session_id, pcm) {
        log::warn!("[ios-keyboard] rejected native PCM: {error}");
    }
}

#[derive(Clone, Copy, Debug, Default, Deserialize)]
#[serde(rename_all = "lowercase")]
enum TranscriptionMode {
    #[default]
    Smart,
    Verbatim,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BridgeRequest {
    action: String,
    request_id: Option<String>,
    mode: Option<TranscriptionMode>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct BridgeState {
    server_id: Option<String>,
    revision: u64,
    service_ready: bool,
    microphone_ready: bool,
    status: String,
    request_id: Option<String>,
    transcribed_text: Option<String>,
    result_created_at: Option<f64>,
    last_error: Option<String>,
    interface_language: String,
}

impl BridgeState {
    fn new() -> Self {
        Self {
            server_id: Some(uuid::Uuid::new_v4().to_string()),
            revision: 1,
            service_ready: false,
            microphone_ready: false,
            status: "idle".into(),
            request_id: None,
            transcribed_text: None,
            result_created_at: None,
            last_error: None,
            interface_language: "chinese".into(),
        }
    }

    fn touch(&mut self) {
        self.revision = self.revision.wrapping_add(1);
    }
}

struct KeyboardBridge {
    backend: Arc<OpenLessBackend>,
    state: Mutex<BridgeState>,
    mode: Mutex<TranscriptionMode>,
    session: Mutex<Option<SessionId>>,
}

impl KeyboardBridge {
    async fn selected_asr_provider_type(&self) -> Result<String, openless_core::BackendError> {
        let active_id = self.backend.active_provider(ProviderSlot::Asr).await?;
        Ok(self
            .backend
            .list_channels(openless_core::ChannelKind::Asr)
            .await?
            .into_iter()
            .find(|channel| channel.id == active_id)
            .map(|channel| channel.provider_type)
            .unwrap_or(active_id))
    }

    async fn selected_asr_is_ready(&self) -> bool {
        match self.selected_asr_provider_type().await {
            Ok(provider) if provider == crate::chatgpt_asr::PROVIDER_ID => {
                openless_core::polish::CodexOAuthCredentials::load_default().is_ok()
            }
            Ok(_) => true,
            Err(error) => {
                log::warn!("[ios-keyboard] resolve active ASR failed: {error}");
                false
            }
        }
    }

    async fn snapshot(&self) -> BridgeState {
        let backend = self.backend.snapshot();
        let mut state = self.state.lock().clone();
        state.service_ready = self.selected_asr_is_ready().await;
        state.microphone_ready = backend.dictation.recording_ready;
        state
    }

    async fn update(&self, mutate: impl FnOnce(&mut BridgeState)) -> BridgeState {
        let mut state = self.state.lock();
        mutate(&mut state);
        state.touch();
        drop(state);
        self.snapshot().await
    }

    async fn handle(self: &Arc<Self>, request: BridgeRequest) -> BridgeState {
        match request.action.as_str() {
            "state" | "heartbeat" => self.snapshot().await,

            "startRecording" => {
                if !self.selected_asr_is_ready().await {
                    return self.update(|state| {
                        state.status = "error".into();
                        state.last_error = Some("请先在 OpenLess 中登录 GPT".into());
                    }).await;
                }

                let request_id = request.request_id.unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
                let mode = request.mode.unwrap_or_default();
                *self.mode.lock() = mode;
                self.update(|state| {
                    state.status = "starting".into();
                    state.request_id = Some(request_id.clone());
                    state.transcribed_text = None;
                    state.result_created_at = None;
                    state.last_error = None;
                }).await;

                let this = Arc::clone(self);
                tauri::async_runtime::spawn(async move {
                    if !this.backend.snapshot().running {
                        if let Err(error) = this.backend.start().await {
                            this.update(|state| {
                                state.status = "error".into();
                                state.last_error = Some(error.to_string());
                            }).await;
                            return;
                        }
                    }

                    match this.backend.start_external_dictation_with_options(DictationStartOptions {
                        insert_text: false,
                        ..DictationStartOptions::default()
                    }).await {
                        Ok(session_id) => {
                            *this.session.lock() = Some(session_id);
                            if start_native_audio() {
                                this.update(|state| {
                                    state.status = "recording".into();
                                    state.last_error = None;
                                }).await;
                            } else {
                                this.session.lock().take();
                                let _ = this.backend.cancel_dictation(Some(session_id)).await;
                                this.update(|state| {
                                    state.status = "error".into();
                                    state.last_error = Some("OpenLess 无法启动 iPhone 麦克风采集".into());
                                }).await;
                            }
                        }
                        Err(error) => {
                            this.update(|state| {
                                state.status = "error".into();
                                state.last_error = Some(error.to_string());
                            }).await;
                        }
                    }
                });

                self.snapshot().await
            }

            "stopRecording" => {
                self.update(|state| {
                    state.status = "transcribing".into();
                    state.last_error = None;
                }).await;

                let this = Arc::clone(self);
                tauri::async_runtime::spawn(async move {
                    stop_native_audio();
                    let session_id = this.session.lock().take();
                    let result = match session_id {
                        Some(_) => this.backend.stop_dictation_with_options(
                            DictationStopOptions {
                                translation_requested: None,
                                quick_note: Some(false),
                            },
                        ).await,
                        None => Err(openless_core::BackendError::new(
                            openless_core::BackendErrorCode::InvalidState,
                            "native audio session is not active",
                        )),
                    };

                    match result {
                        Ok(result) => {
                            let mode = *this.mode.lock();
                            let text = match mode {
                                TranscriptionMode::Smart => result.polished_text,
                                TranscriptionMode::Verbatim => result.raw_text,
                            };
                            this.update(|state| {
                                state.status = "completed".into();
                                state.transcribed_text = Some(text);
                                state.result_created_at = Some(apple_reference_seconds_now());
                                state.last_error = None;
                            }).await;
                        }
                        Err(error) => {
                            this.update(|state| {
                                state.status = "error".into();
                                state.last_error = Some(error.to_string());
                            }).await;
                        }
                    }
                });

                self.snapshot().await
            }

            "acknowledgeResult" => self.update(|state| {
                state.status = "idle".into();
                state.request_id = None;
                state.transcribed_text = None;
                state.result_created_at = None;
                state.last_error = None;
            }).await,

            _ => self.update(|state| {
                state.status = "error".into();
                state.last_error = Some("未知键盘命令".into());
            }).await,
        }
    }
}

pub fn start(backend: Arc<OpenLessBackend>) {
    let bridge = Arc::new(KeyboardBridge {
        backend,
        state: Mutex::new(BridgeState::new()),
        mode: Mutex::new(TranscriptionMode::Smart),
        session: Mutex::new(None),
    });
    let _ = NATIVE_AUDIO_BRIDGE.set(Arc::downgrade(&bridge));

    tauri::async_runtime::spawn(async move {
        loop {
            match TcpListener::bind(("127.0.0.1", PORT)).await {
                Ok(listener) => {
                    log::info!("[ios-keyboard] bridge listening on 127.0.0.1:{PORT}");
                    loop {
                        match listener.accept().await {
                            Ok((stream, _)) => {
                                let bridge = Arc::clone(&bridge);
                                tauri::async_runtime::spawn(async move {
                                    let _ = handle_connection(stream, bridge).await;
                                });
                            }
                            Err(error) => {
                                log::warn!("[ios-keyboard] accept failed: {error}");
                                break;
                            }
                        }
                    }
                }
                Err(error) => {
                    log::warn!("[ios-keyboard] bind failed: {error}; retrying");
                    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                }
            }
        }
    });
}

async fn handle_connection(
    mut stream: TcpStream,
    bridge: Arc<KeyboardBridge>,
) -> Result<(), std::io::Error> {
    let mut buffer = Vec::with_capacity(4096);
    let mut chunk = [0_u8; 4096];

    loop {
        let read = stream.read(&mut chunk).await?;
        if read == 0 {
            break;
        }
        buffer.extend_from_slice(&chunk[..read]);
        if buffer.len() > 65_536 {
            write_response(&mut stream, 413, &[]).await?;
            return Ok(());
        }
        if request_complete(&buffer) {
            break;
        }
    }

    let parsed = match parse_request(&buffer) {
        Ok(value) => value,
        Err(status) => {
            write_response(&mut stream, status, &[]).await?;
            return Ok(());
        }
    };

    let state = bridge.handle(parsed).await;
    let body = serde_json::to_vec(&state).unwrap_or_else(|_| b"{}".to_vec());
    write_response(&mut stream, 200, &body).await
}

fn request_complete(data: &[u8]) -> bool {
    let Some(header_end) = find_bytes(data, b"\r\n\r\n") else { return false };
    let header = String::from_utf8_lossy(&data[..header_end]);
    let content_length = header
        .lines()
        .find_map(|line| {
            let (name, value) = line.split_once(':')?;
            name.eq_ignore_ascii_case("content-length")
                .then(|| value.trim().parse::<usize>().ok())
                .flatten()
        })
        .unwrap_or(0);
    data.len() >= header_end + 4 + content_length
}

fn parse_request(data: &[u8]) -> Result<BridgeRequest, u16> {
    let header_end = find_bytes(data, b"\r\n\r\n").ok_or(400_u16)?;
    let header = String::from_utf8_lossy(&data[..header_end]);
    let mut lines = header.lines();
    let request_line = lines.next().ok_or(400_u16)?;
    let mut parts = request_line.split_whitespace();
    let method = parts.next().ok_or(400_u16)?;
    let path = parts.next().ok_or(400_u16)?;

    let mut protocol_ok = false;
    let mut content_length = 0_usize;
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            if name.eq_ignore_ascii_case("x-voiceking-protocol") {
                protocol_ok = value.trim() == PROTOCOL_VERSION;
            } else if name.eq_ignore_ascii_case("content-length") {
                content_length = value.trim().parse().unwrap_or(0);
            }
        }
    }
    if !protocol_ok {
        return Err(400);
    }

    if method == "GET" && path == "/state" {
        return Ok(BridgeRequest {
            action: "state".into(),
            request_id: None,
            mode: None,
        });
    }

    if method != "POST" || path != "/command" || content_length == 0 {
        return Err(400);
    }

    let body_start = header_end + 4;
    let body_end = body_start.saturating_add(content_length);
    if body_end > data.len() {
        return Err(400);
    }

    serde_json::from_slice(&data[body_start..body_end]).map_err(|_| 400_u16)
}

async fn write_response(
    stream: &mut TcpStream,
    status: u16,
    body: &[u8],
) -> Result<(), std::io::Error> {
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        413 => "Payload Too Large",
        _ => "Error",
    };
    let header = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(header.as_bytes()).await?;
    stream.write_all(body).await?;
    stream.shutdown().await
}

fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|window| window == needle)
}

fn apple_reference_seconds_now() -> f64 {
    const APPLE_REFERENCE_UNIX: f64 = 978_307_200.0;
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_secs_f64() - APPLE_REFERENCE_UNIX)
        .unwrap_or(0.0)
}
