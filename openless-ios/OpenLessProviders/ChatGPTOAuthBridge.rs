use serde::Serialize;
use std::path::PathBuf;
use tauri::Manager;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatGptOAuthStatus {
    pub state: String,
    pub signed_in: bool,
    pub message: Option<String>,
}

fn bridge_directory(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    let documents = app
        .path()
        .document_dir()
        .map_err(|error| format!("OpenLess could not resolve the iOS Documents directory: {error}"))?;
    let directory = documents.join("OpenLessGPT");
    std::fs::create_dir_all(&directory)
        .map_err(|error| format!("failed to prepare ChatGPT login bridge: {error}"))?;
    Ok(directory)
}

fn auth_path(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    Ok(bridge_directory(app)?.join("auth.json"))
}

fn configure_codex_auth_path(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    let path = auth_path(app)?;
    std::env::set_var("OPENLESS_CODEX_AUTH_PATH", &path);
    Ok(path)
}

#[tauri::command]
pub fn chatgpt_oauth_begin(app: tauri::AppHandle) -> Result<(), String> {
    let directory = bridge_directory(&app)?;
    let _ = configure_codex_auth_path(&app)?;

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

    std::fs::write(
        directory.join("openless-login-state.json"),
        serde_json::to_vec(&state).unwrap_or_default(),
    )
    .map_err(|error| format!("failed to update ChatGPT login state: {error}"))?;

    Ok(())
}

#[tauri::command]
pub fn chatgpt_oauth_status(app: tauri::AppHandle) -> ChatGptOAuthStatus {
    let directory = match bridge_directory(&app) {
        Ok(path) => path,
        Err(message) => {
            return ChatGptOAuthStatus {
                state: "error".to_string(),
                signed_in: false,
                message: Some(message),
            }
        }
    };

    let auth = match configure_codex_auth_path(&app) {
        Ok(path) => path,
        Err(message) => {
            return ChatGptOAuthStatus {
                state: "error".to_string(),
                signed_in: false,
                message: Some(message),
            }
        }
    };

    let signed_in =
        openless_core::polish::CodexOAuthCredentials::load_from_path(&auth).is_ok();

    if signed_in {
        return ChatGptOAuthStatus {
            state: "signed_in".to_string(),
            signed_in: true,
            message: None,
        };
    }

    let mut state = "idle".to_string();
    let mut message = None;
    let state_path = directory.join("openless-login-state.json");

    if let Ok(raw) = std::fs::read_to_string(state_path) {
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

    ChatGptOAuthStatus {
        state,
        signed_in: false,
        message,
    }
}
