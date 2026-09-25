from pathlib import Path

p = Path("src-tauri/src/commands/providers.rs")
text = p.read_text()

old = """    let kind = parse_provider_kind(&kind)?;
    core.services()
        .provider
        .validate(openless_core::ProviderRequest {
            kind,
            channel_id,
            thinking_enabled: core.get_preferences().llm_thinking_enabled,
        })
        .await
        .map_err(|error| error.message)
"""
new = """    let kind = parse_provider_kind(&kind)?;

    #[cfg(target_os = "ios")]
    {
        if kind == openless_core::ProviderKind::Asr {
            if let Some(channel_id_ref) = channel_id.as_ref() {
                let channels = core
                    .list_channels(openless_core::ChannelKind::Asr)
                    .await
                    .map_err(|error| error.to_string())?;
                if channels.iter().any(|channel| {
                    channel.id == *channel_id_ref && channel.provider_type == "chatgpt_oauth"
                }) {
                    crate::chatgpt_asr::validate_oauth_provider()
                        .await
                        .map_err(|error| error.message)?;
                    return Ok(openless_core::ProviderCheckResult { ok: true });
                }
            }
        }
    }

    core.services()
        .provider
        .validate(openless_core::ProviderRequest {
            kind,
            channel_id,
            thinking_enabled: core.get_preferences().llm_thinking_enabled,
        })
        .await
        .map_err(|error| error.message)
"""

if old not in text:
    raise SystemExit("provider validation command anchor missing")

text = text.replace(old, new, 1)
p.write_text(text)

if "validate_oauth_provider" not in p.read_text():
    raise SystemExit("GPT ASR validation hook was not wired")
