use serde::Serialize;
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatGptOAuthStatus {
    pub state: String,
    pub signed_in: bool,
    pub message: Option<String>,
}

#[cfg(target_os = "ios")]
unsafe extern "C" {
    fn openless_chatgpt_begin_login();
}

#[tauri::command]
pub fn chatgpt_oauth_begin() -> Result<(), String> {
    #[cfg(target_os = "ios")]
    unsafe {
        openless_chatgpt_begin_login();
        return Ok(());
    }

    #[allow(unreachable_code)]
    Err("ChatGPT OAuth bridge is only available on iOS".to_string())
}

#[tauri::command]
pub fn chatgpt_oauth_status() -> ChatGptOAuthStatus {
    let signed_in = openless_core::polish::CodexOAuthCredentials::load_default().is_ok();
    if signed_in {
        return ChatGptOAuthStatus {
            state: "signed_in".to_string(),
            signed_in: true,
            message: None,
        };
    }

    let mut state = "idle".to_string();
    let mut message = None;

    if let Some(path) = login_state_path() {
        if let Ok(raw) = std::fs::read_to_string(path) {
            if let Ok(json) = serde_json::from_str::<serde_json::Value>(&raw) {
                if let Some(value) = json.get("state").and_then(|v| v.as_str()) {
                    state = value.to_string();
                }
                message = json
                    .get("message")
                    .and_then(|v| v.as_str())
                    .map(ToOwned::to_owned);
            }
        }
    }

    ChatGptOAuthStatus {
        state,
        signed_in: false,
        message,
    }
}

fn login_state_path() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .map(|home| home.join(".codex").join("openless-login-state.json"))
}
