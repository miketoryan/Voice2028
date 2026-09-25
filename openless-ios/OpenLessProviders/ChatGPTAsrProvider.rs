use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use futures_util::future::BoxFuture;
use openless_core::{
    encode_dictation_wav, AudioConsumer, BackendError, BackendErrorCode, DictationContext,
    SessionId, TextStreamSink, TranscriptOutput, TranscriptionEngine, TranscriptionSession,
};
use parking_lot::Mutex;
use reqwest::multipart::{Form, Part};

pub const PROVIDER_ID: &str = "chatgpt_oauth";
const TRANSCRIBE_ENDPOINT: &str = "https://chatgpt.com/backend-api/transcribe";

#[derive(Default)]
pub struct ChatGptOAuthTranscriptionEngine;

impl ChatGptOAuthTranscriptionEngine {
    pub fn new() -> Self {
        Self
    }
}

impl TranscriptionEngine for ChatGptOAuthTranscriptionEngine {
    fn start(
        &self,
        _session_id: SessionId,
        context: Arc<DictationContext>,
        _partials: Arc<dyn TextStreamSink>,
    ) -> BoxFuture<'static, Result<Arc<dyn TranscriptionSession>, BackendError>> {
        let language = context.asr.language.clone();
        Box::pin(async move {
            let client = reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(600))
                .build()
                .map_err(|error| provider_error(format!("failed to create ChatGPT HTTP client: {error}")))?;

            Ok(Arc::new(ChatGptOAuthTranscriptionSession {
                pcm: Mutex::new(Vec::new()),
                language,
                client,
                finished: AtomicBool::new(false),
                cancelled: AtomicBool::new(false),
            }) as Arc<dyn TranscriptionSession>)
        })
    }
}

struct ChatGptOAuthTranscriptionSession {
    pcm: Mutex<Vec<u8>>,
    language: Option<String>,
    client: reqwest::Client,
    finished: AtomicBool,
    cancelled: AtomicBool,
}

impl AudioConsumer for ChatGptOAuthTranscriptionSession {
    fn consume_pcm_chunk(&self, pcm: &[u8]) {
        if self.cancelled.load(Ordering::Acquire) || self.finished.load(Ordering::Acquire) {
            return;
        }
        self.pcm.lock().extend_from_slice(pcm);
    }
}

impl TranscriptionSession for ChatGptOAuthTranscriptionSession {
    fn finish(&self) -> BoxFuture<'static, Result<TranscriptOutput, BackendError>> {
        if self.finished.swap(true, Ordering::AcqRel) {
            return Box::pin(async {
                Err(BackendError::new(
                    BackendErrorCode::Busy,
                    "ChatGPT transcription session has already been finalized",
                ))
            });
        }

        if self.cancelled.load(Ordering::Acquire) {
            return Box::pin(async {
                Err(BackendError::new(
                    BackendErrorCode::Cancelled,
                    "ChatGPT transcription was cancelled",
                ))
            });
        }

        let pcm = self.pcm.lock().clone();
        let language = self.language.clone();
        let client = self.client.clone();

        Box::pin(async move {
            if pcm.is_empty() {
                return Err(provider_error("no recorded audio was received"));
            }

            let duration_ms = ((pcm.len() as u64 / 2) * 1000) / 16_000;
            let wav = encode_dictation_wav(&pcm)?;
            let credentials = openless_core::polish::CodexOAuthCredentials::load_default()
                .map_err(|error| provider_error(format!("ChatGPT login unavailable: {error}")))?;

            let audio_part = Part::bytes(wav)
                .file_name("dictation.wav")
                .mime_str("audio/wav")
                .map_err(|error| provider_error(format!("invalid audio multipart: {error}")))?;

            let mut form = Form::new().part("file", audio_part);
            if let Some(language) = language.filter(|value| !value.trim().is_empty()) {
                form = form.text("language", language);
            }

            let response = client
                .post(TRANSCRIBE_ENDPOINT)
                .header("Authorization", format!("Bearer {}", credentials.access_token))
                .header("ChatGPT-Account-Id", credentials.account_id)
                .header("originator", "Codex Desktop")
                .header("User-Agent", "Codex Desktop/26.707.8479.0 (iOS; arm64)")
                .multipart(form)
                .send()
                .await
                .map_err(|error| provider_error(format!("ChatGPT transcription request failed: {error}")))?;

            let status = response.status();
            let body = response
                .bytes()
                .await
                .map_err(|error| provider_error(format!("failed to read ChatGPT transcription response: {error}")))?;

            if !status.is_success() {
                let detail = String::from_utf8_lossy(&body);
                let preview: String = detail.chars().take(600).collect();
                return Err(provider_error(format!(
                    "ChatGPT transcription HTTP {}: {}",
                    status.as_u16(),
                    preview
                )));
            }

            let json: serde_json::Value = serde_json::from_slice(&body)
                .map_err(|error| provider_error(format!("invalid ChatGPT transcription JSON: {error}")))?;
            let text = json
                .get("text")
                .and_then(|value| value.as_str())
                .unwrap_or_default()
                .trim()
                .to_string();

            Ok(TranscriptOutput { text, duration_ms })
        })
    }

    fn cancel(&self) -> BoxFuture<'static, Result<(), BackendError>> {
        self.cancelled.store(true, Ordering::Release);
        self.pcm.lock().clear();
        Box::pin(async { Ok(()) })
    }
}

fn provider_error(message: impl Into<String>) -> BackendError {
    BackendError::new(BackendErrorCode::Provider, message.into())
}
