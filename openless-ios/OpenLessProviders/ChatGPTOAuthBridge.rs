use serde::Serialize;
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatGptOAuthStatus {
    pub state: String,
    pub signed_in: bool,
    pub message: Option<String>,
}

#[tauri::command]
pub fn chatgpt_oauth_begin() -> Result<(), String> {
    let directory = codex_directory()
        .ok_or_else(|| "OpenLess could not resolve the iOS app home directory".to_string())?;

    std::fs::create_dir_all(&directory)
        .map_err(|error| format!("failed to prepare ChatGPT login bridge: {error}"))?;

    let request = serde_json::json!({
        "requestedAt": std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|value| value.as_secs_f64())
            .unwrap_or_default()
    });

    std::fs::write(
        directory.join("openless-login-request.json"),
        serde_json::to_vec(&request)
            .map_err(|error| format!("failed to encode ChatGPT login request: {error}"))?,
    )
    .map_err(|error| format!("failed to submit ChatGPT login request: {error}"))?;

    let state = serde_json::json!({
        "state": "opening",
        "updatedAt": std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|value| value.as_secs_f64())
            .unwrap_or_default()
    });
    let _ = std::fs::write(
        directory.join("openless-login-state.json"),
        serde_json::to_vec(&state).unwrap_or_default(),
    );

    Ok(())
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

fn codex_directory() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .map(|home| home.join(".codex"))
}

fn login_state_path() -> Option<PathBuf> {
    codex_directory().map(|directory| directory.join("openless-login-state.json"))
}
